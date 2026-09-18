//
//  StockGoldStore.swift
//  자산 포트폴리오 앱
//
//  국내주식/해외주식/금 보유종목의 종목코드·수량·매입단가를 "이 기기 안에만" 저장하는
//  로컬 CRUD 스토어입니다.
//
//  ⚠️ 구현 방식에 대한 안내: 요청하신 SwiftData는 iOS17부터 지원되는데, 이 프로젝트의
//  최소 타겟은 iOS16이라 그대로는 쓸 수 없습니다. @AppStorage는 배열/구조체를 직접
//  저장하지 못해서(문자열·숫자·Bool 등 단순 값 전용), 실무에서 가장 널리 쓰는 절충안인
//  "Codable 배열을 JSON으로 직렬화해 기기 로컬 파일에 저장 + @Published로 화면에 반영"
//  방식으로 만들었습니다. 기존 코인 저장 로직도 min iOS16 환경이라면 같은 방식이거나
//  UserDefaults+JSON 방식일 가능성이 높습니다 — 실제 코인 스토어 파일을 보시고 저장
//  위치(파일 vs UserDefaults)만 맞춰 주시면 패턴은 동일합니다.
//

import Foundation

enum HoldingAssetClass: String, Codable, CaseIterable, Identifiable {
    case domesticStock = "국내주식"
    case foreignStock = "해외주식"
    case gold = "금"

    var id: String { rawValue }
}

struct StockGoldHolding: Identifiable, Codable, Equatable {
    var id: UUID = UUID()
    var assetClass: HoldingAssetClass

    /// 국내주식: 종목코드(예: "005930"), 해외주식: 티커(예: "AAPL"),
    /// 금: 시세 조회에 쓰이지 않으므로 임의 식별용 문자열(예: "금현물")을 넣어두면 됩니다.
    var symbol: String

    /// 목록에 보여줄 이름(사용자가 직접 입력, 예: "삼성전자", "애플", "골드바 3.75g")
    var displayName: String

    /// 국내/해외주식: 보유 주수, 금: 보유 중량(g)
    var quantity: Double

    /// 평균매입단가 — 국내: 원/주, 해외: 달러/주, 금: 원/g
    var avgCost: Double

    /// 종목코드가 prices.json 유니버스 밖에 있을 때(상장폐지·신규상장 지연 등) 사용자가
    /// 직접 입력한 현재가. 이 값이 있으면 prices.json 조회보다 우선합니다.
    /// 금은 항상 prices.json의 KRX 금시세를 쓰므로 이 필드를 쓰지 않습니다.
    var manualPrice: Double?

    var memo: String = ""
    var createdAt: Date = Date()
}

@MainActor
final class StockGoldStore: ObservableObject {
    static let shared = StockGoldStore()

    @Published private(set) var holdings: [StockGoldHolding] = []

    private let fileURL: URL = {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return dir.appendingPathComponent("stock_gold_holdings.json")
    }()

    private init() {
        load()
    }

    func add(_ holding: StockGoldHolding) {
        holdings.append(holding)
        save()
    }

    func update(_ holding: StockGoldHolding) {
        guard let idx = holdings.firstIndex(where: { $0.id == holding.id }) else { return }
        holdings[idx] = holding
        save()
    }

    func delete(id: UUID) {
        holdings.removeAll { $0.id == id }
        save()
    }

    func holdings(for assetClass: HoldingAssetClass) -> [StockGoldHolding] {
        holdings.filter { $0.assetClass == assetClass }
    }

    // MARK: 저장/불러오기

    private func save() {
        do {
            let data = try JSONEncoder().encode(holdings)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            print("StockGoldStore 저장 실패: \(error)")
        }
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL) else { return }
        do {
            holdings = try JSONDecoder().decode([StockGoldHolding].self, from: data)
        } catch {
            print("StockGoldStore 불러오기 실패: \(error)")
        }
    }
}
