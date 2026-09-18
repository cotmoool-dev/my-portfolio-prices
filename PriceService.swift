//
//  PriceService.swift
//  자산 포트폴리오 앱
//
//  GitHub Actions가 매일 갱신하는 prices.json(국내주식 전종목·해외주식 유니버스·금현물·환율)을
//  raw.githubusercontent.com에서 내려받아 디코딩하고, 마지막으로 성공한 데이터를 기기에
//  캐시해 두는 서비스입니다. 코인 시세(CoinGecko)는 이 파일에서 다루지 않습니다 — 기존
//  코인 연동 코드를 그대로 쓰시면 됩니다.
//
//  githubOwner/githubRepo는 https://github.com/cotmoool-dev/my-portfolio-prices 로
//  채워져 있습니다. 저장소 이름을 나중에 바꾸시면 이 두 줄만 다시 고치면 됩니다.
//

import Foundation

// MARK: - 데이터 모델

/// prices.json 최상위 구조. kr/us는 값이 없을 수도 있어 옵셔널이 아니라 빈 딕셔너리로
/// 내려오지만, gold_krx/fx는 수집 실패 시 "{}"(빈 객체)로 내려올 수 있어 내부 필드를
/// 옵셔널로 두었습니다(빈 객체가 와도 디코딩이 실패하지 않도록).
struct PricesPayload: Codable {
    let date: String
    let kr: [String: Double]   // 종목코드 -> 종가(원)
    let us: [String: Double]   // 티커 -> 종가(달러)
    let goldKrx: GoldInfo?
    let fx: FxInfo?

    enum CodingKeys: String, CodingKey {
        case date, kr, us
        case goldKrx = "gold_krx"
        case fx
    }
}

struct GoldInfo: Codable {
    let pricePerG: Double?   // 원/g, 수집 실패 시 nil일 수 있음

    /// "krx_public_data" = 공공데이터포털 금융위원회_일반상품시세정보(KRX 금시장 종가)
    /// "intl_futures_est" = 공공데이터 API 실패 시 국제 금선물 환산 추정치
    /// 어떤 출처인지에 따라 화면 하단 문구가 달라집니다.
    let source: String?

    enum CodingKeys: String, CodingKey {
        case pricePerG = "price_per_g"
        case source
    }
}

struct FxInfo: Codable {
    let usdkrw: Double?
}

// MARK: - PriceService

@MainActor
final class PriceService: ObservableObject {
    static let shared = PriceService()

    private let githubOwner = "cotmoool-dev"
    private let githubRepo = "my-portfolio-prices"
    private var pricesURL: URL {
        URL(string: "https://raw.githubusercontent.com/\(githubOwner)/\(githubRepo)/main/prices.json")!
    }

    @Published private(set) var payload: PricesPayload?
    @Published private(set) var lastFetchedAt: Date?
    @Published private(set) var isLoading = false
    @Published private(set) var lastErrorMessage: String?

    // 파일 기반 캐시(국내주식 전종목까지 들어가면 UserDefaults보다 파일이 적합해서
    // Documents가 아니라 앱 전용 캐시 디렉터리를 씁니다 — 용량이 커도 안전합니다).
    private let cacheFileURL: URL = {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        return dir.appendingPathComponent("prices_cache.json")
    }()
    private let lastFetchedKey = "PriceService.lastFetchedAt"

    private init() {
        loadCacheFromDisk()
        lastFetchedAt = UserDefaults.standard.object(forKey: lastFetchedKey) as? Date
    }

    /// 코인 화면의 "지금 시세 가져오기"와 대응되는, 국내주식/해외주식/금 공용 새로고침 버튼에서 호출합니다.
    func fetchPrices() async {
        isLoading = true
        lastErrorMessage = nil
        defer { isLoading = false }

        do {
            let (data, response) = try await URLSession.shared.data(from: pricesURL)
            if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                throw URLError(.badServerResponse)
            }

            // 파일이 클 수 있으니 디코딩은 백그라운드 스레드에서 수행하고, 결과만 메인으로 가져옵니다.
            let decoded = try await Task.detached(priority: .userInitiated) {
                try JSONDecoder().decode(PricesPayload.self, from: data)
            }.value

            self.payload = decoded
            self.lastFetchedAt = Date()
            UserDefaults.standard.set(self.lastFetchedAt, forKey: lastFetchedKey)
            saveCacheToDisk(data)
        } catch {
            // 네트워크 실패 시에는 마지막 캐시를 그대로 유지합니다(오프라인에서도 화면이 비지 않도록).
            lastErrorMessage = "시세를 불러오지 못했어요. 마지막으로 받은 데이터를 표시합니다. (\(error.localizedDescription))"
        }
    }

    // MARK: 조회 헬퍼 — 화면에서는 이 함수들로만 값을 찾습니다(전체 목록을 순회하지 않음)

    func krClose(code: String) -> Double? {
        payload?.kr[code]
    }

    func usClose(ticker: String) -> Double? {
        payload?.us[ticker]
    }

    var goldPricePerGram: Double? {
        payload?.goldKrx?.pricePerG
    }

    /// 금 시세가 공공데이터포털(KRX 금시장)에서 온 값인지 여부.
    /// true면 KOGL 출처 표기를, false면 "국제시세 환산 추정치" 안내를 보여줍니다.
    var isGoldFromPublicData: Bool {
        payload?.goldKrx?.source == "krx_public_data"
    }

    var usdKrw: Double? {
        payload?.fx?.usdkrw
    }

    /// 사용자가 입력한 종목코드/티커가 이번에 수집된 유니버스 안에 있는지 확인합니다.
    /// AssetEditView에서 "시세 데이터에 없는 종목입니다" 안내에 씁니다.
    func isKnownDomesticStock(code: String) -> Bool { payload?.kr[code] != nil }
    func isKnownForeignStock(ticker: String) -> Bool { payload?.us[ticker] != nil }

    // MARK: 로컬 캐시

    private func saveCacheToDisk(_ data: Data) {
        try? data.write(to: cacheFileURL, options: .atomic)
    }

    private func loadCacheFromDisk() {
        guard let data = try? Data(contentsOf: cacheFileURL) else { return }
        payload = try? JSONDecoder().decode(PricesPayload.self, from: data)
    }
}
