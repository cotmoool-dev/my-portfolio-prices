#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
fetch_prices.py
================
GitHub Actions에서 매일 실행되어 국내주식 전종목 · 해외주식(S&P500+나스닥100) · 금현물(KRX) ·
원/달러 환율을 수집해서 저장소 루트의 prices.json 하나로 저장하는 스크립트입니다.

- 코인 시세는 여기서 다루지 않습니다(기존 앱이 CoinGecko를 직접 호출하는 로직을 그대로 씁니다).
- 개별 사용자의 "보유종목"은 절대 다루지 않습니다. 여기서는 시장 전체(국내주식)와
  공개 지수 구성종목 전체(해외주식)의 시세만 수집합니다 — 특정인의 포트폴리오를
  유추할 수 없게 하기 위한 설계입니다.
- 일부 항목이 실패해도 스크립트 전체가 죽지 않도록, 각 구간을 try/except로 감싸고
  실패한 티커만 결과에서 빠집니다.

출력 스키마:
{
  "date": "YYYY-MM-DD",
  "kr":  { "005930": 71200, ... },       # 종목코드 -> 종가(원)
  "us":  { "AAPL": 231.5, ... },         # 티커 -> 종가(달러)
  "gold_krx": { "price_per_g": 132500 }, # KRX 금 1g당 종가(원, 정수)
  "fx": { "usdkrw": 1391.2 }
}
"""

import json
import os
import sys
import time
import datetime as dt
from pathlib import Path

import requests

ROOT = Path(__file__).resolve().parent
UNIVERSE_PATH = ROOT / "us_universe.json"
OUTPUT_PATH = ROOT / "prices.json"

KST = dt.timezone(dt.timedelta(hours=9))


def today_kst() -> dt.date:
    return dt.datetime.now(tz=KST).date()


# ---------------------------------------------------------------------------
# 공용: yfinance 종가 일괄 다운로드 헬퍼 (국내주식/해외주식 양쪽에서 재사용)
# ---------------------------------------------------------------------------
# ⚠️ 2026-09-22 변경: 국내주식 수집에 쓰던 pykrx가 "KRX 로그인 실패: KRX_ID 또는
# KRX_PW 환경 변수가 설정되지 않았습니다" 에러로 완전히 막혔습니다. 2026년 9월경
# pykrx가 KRX 정식 인증을 요구하도록 바뀐 것으로 보이며(커뮤니티 사례:
# kwondoyun07/K-PaperTrade #44), 로그인 계정을 새로 만들어 비밀정보로 관리하는 대신
# 아예 pykrx 의존을 없앴습니다.
#
# 대체 방식: 로그인이 필요 없는 FinanceDataReader로 "코스피+코스닥 전종목 코드
# 목록"만 받아오고(가격 정보는 없음), 실제 종가는 이미 검증된 해외주식용 yfinance
# 일괄 다운로드 로직을 그대로 재사용해서 받습니다(종목코드에 .KS/.KQ 접미사만 붙이면
# yfinance가 국내 종목도 그대로 조회해 줍니다).
def _download_close_chunk(tickers: list, chunk_size: int = 100, retries: int = 1) -> dict:
    """
    yfinance로 티커 목록의 최근 종가를 청크 단위로 받아옵니다. 국내주식(.KS/.KQ 접미사)과
    해외주식(원본 티커) 양쪽에서 공용으로 씁니다. 티커를 한 번에 너무 많이 넣으면(수백~수천 개)
    일부가 누락되는 경우가 있어서 chunk_size 단위로 나눠 요청하고, 청크 하나가 실패하면
    가볍게 재시도한 뒤 그래도 안 되면 그 청크만 건너뜁니다(전체 스크립트는 죽지 않도록).
    """
    try:
        import yfinance as yf
    except Exception as e:
        print(f"[시세수집] yfinance import 실패: {e}", file=sys.stderr)
        return {}

    result = {}
    chunks = [tickers[i:i + chunk_size] for i in range(0, len(tickers), chunk_size)]
    for idx, chunk in enumerate(chunks, start=1):
        df = None
        for attempt in range(1 + retries):
            try:
                df = yf.download(
                    tickers=chunk,
                    period="5d",          # 주말·공휴일 대비 여유 있게 최근 5거래일
                    interval="1d",
                    group_by="ticker",
                    auto_adjust=False,
                    threads=True,
                    progress=False,
                )
                break
            except Exception as e:
                if attempt < retries:
                    print(f"[시세수집] {idx}/{len(chunks)} 청크 다운로드 실패, 재시도합니다: {e}", file=sys.stderr)
                    time.sleep(2)
                else:
                    print(f"[시세수집] {idx}/{len(chunks)} 청크 다운로드 최종 실패, 건너뜀: {e}", file=sys.stderr)

        if df is None:
            continue

        for t in chunk:
            try:
                if len(chunk) == 1:
                    close_series = df["Close"]
                else:
                    close_series = df[t]["Close"]
                close_series = close_series.dropna()
                if not close_series.empty:
                    result[t] = float(close_series.iloc[-1])
            except Exception:
                continue  # 상장폐지·티커 오류 등 개별 실패는 건너뛰고 계속 진행
        time.sleep(1)  # 청크 사이 살짝 쉬어서 과도한 연속 요청 방지

    return result


# ---------------------------------------------------------------------------
# 1) 국내주식: FinanceDataReader(종목코드 목록) + yfinance(.KS/.KQ 종가)
# ---------------------------------------------------------------------------
def load_kr_universe() -> dict:
    """
    코스피+코스닥 전종목 코드를 FinanceDataReader로 가져옵니다. 로그인/인증이 필요 없고,
    Symbol(종목코드)·Name만 제공하므로 가격은 여기서 얻을 수 없습니다 — 아래
    fetch_kr_close_prices()에서 yfinance로 따로 받습니다.
    반환값: {"005930": "KS", "247540": "KQ", ...} (종목코드 -> yfinance 접미사)
    """
    try:
        import FinanceDataReader as fdr
    except Exception as e:
        print(f"[국내주식] FinanceDataReader import 실패, 이번 회차는 건너뜁니다: {e}", file=sys.stderr)
        return {}

    universe = {}
    for market, suffix in (("KOSPI", "KS"), ("KOSDAQ", "KQ")):
        try:
            df = fdr.StockListing(market)
            code_col = "Code" if "Code" in df.columns else "Symbol"
            for code in df[code_col]:
                code = str(code).strip().zfill(6)
                if code:
                    universe[code] = suffix
        except Exception as e:
            print(f"[국내주식] {market} 종목 목록 조회 실패: {e}", file=sys.stderr)

    print(f"[국내주식] FinanceDataReader에서 {len(universe)}개 종목 코드 로드(코스피+코스닥)")
    return universe


def fetch_kr_close_prices(kr_universe: dict, chunk_size: int = 100) -> dict:
    """
    kr_universe(종목코드 -> "KS"/"KQ")에 접미사를 붙여 yfinance 티커(예: "005930.KS")로
    바꾼 뒤 해외주식과 같은 방식으로 일괄 다운로드하고, 결과를 다시 순수 6자리 종목코드
    기준으로 되돌립니다.
    """
    if not kr_universe:
        return {}

    yf_tickers = [f"{code}.{suffix}" for code, suffix in kr_universe.items()]
    raw = _download_close_chunk(yf_tickers, chunk_size=chunk_size, retries=1)

    result = {}
    for yf_ticker, price in raw.items():
        code = yf_ticker.split(".")[0]
        result[code] = price

    print(f"[국내주식] {len(result)}/{len(kr_universe)}개 종목 수집 성공")
    return result


# ---------------------------------------------------------------------------
# 2) 해외주식: yfinance로 S&P500 + 나스닥100 구성종목 일괄 다운로드
# ---------------------------------------------------------------------------
def load_us_universe() -> list:
    try:
        data = json.loads(UNIVERSE_PATH.read_text(encoding="utf-8"))
        tickers = data.get("tickers", [])
        print(f"[해외주식] us_universe.json에서 {len(tickers)}개 티커 로드")
        return tickers
    except Exception as e:
        print(f"[해외주식] us_universe.json 로드 실패: {e}", file=sys.stderr)
        return []


def fetch_us_close_prices(tickers: list, chunk_size: int = 100) -> dict:
    result = _download_close_chunk(tickers, chunk_size=chunk_size, retries=1)
    print(f"[해외주식] {len(result)}/{len(tickers)}개 티커 수집 성공")
    return result


def fetch_usdkrw() -> float | None:
    try:
        import yfinance as yf
        df = yf.download(tickers="KRW=X", period="5d", interval="1d", progress=False)
        close = df["Close"].dropna()
        if not close.empty:
            return float(close.iloc[-1].item() if hasattr(close.iloc[-1], "item") else close.iloc[-1])
    except Exception as e:
        print(f"[환율] USD/KRW 조회 실패: {e}", file=sys.stderr)
    return None


# ---------------------------------------------------------------------------
# 3) 금현물: 공공데이터포털 금융위원회_일반상품시세정보 getGoldPriceInfo
# ---------------------------------------------------------------------------
# ⚠️ 중요: 아래 base URL·요청 파라미터명·응답 필드명은 같은 계열의 다른 금융위원회 시세
# API(주식/채권/지수/파생상품 시세정보)들이 공통으로 쓰는 표준 패턴을 참고해 작성한
# "최선의 추정"입니다. getGoldPriceInfo만의 정확한 스펙은 이 스크립트를 작성하는
# 시점에 문서 원문을 직접 열어 확인하지 못했으므로, 실제로 사용하시기 전에
# https://www.data.go.kr/data/15094805/openapi.do 의 "상세설명"과 "참고문서(활용가이드)"
# PDF를 꼭 열어서 다음을 확인/수정해 주세요:
#   1) 서비스명이 GetGeneralProductInfoService / operation이 getGoldPriceInfo가 맞는지
#   2) 요청 파라미터 이름(특히 날짜 파라미터가 basDt인지 beginBasDt/endBasDt 조합인지)
#   3) 응답에서 "1g당 종가"에 해당하는 실제 필드 이름
# 아래 코드는 실패 시 원본 응답을 그대로 출력하도록 만들어서, 처음 실행했을 때
# 콘솔 로그만 보고 바로 필드명을 고칠 수 있게 해두었습니다.
# 2026-09-18 확인: 포털 "서비스 정보" 화면의 End Point는
#   https://apis.data.go.kr/1160100/GetGeneralProductInfoService_V2
# 로 표시되어 있었습니다. 다만 오퍼레이션까지 붙인 전체 주소를 직접 호출해 보니 400이
# 떨어져서, 주소 형태가 확정되지 않았습니다(같은 금융위 계열 API들은 중간에 /service/가
# 들어가는 형태도 흔합니다). 그래서 아래처럼 "후보 주소를 순서대로 시도하고, 성공한
# 주소를 그대로 계속 쓰는" 방식으로 바꿨습니다.
#
# 처음 한 번은 GitHub Actions 로그에 각 후보의 HTTP 상태코드와 응답 앞부분,
# 그리고 성공 시 응답 항목의 "실제 키 목록"이 찍힙니다(인증키는 ****로 가려집니다).
# 그 로그만 보면 어떤 주소·어떤 필드가 맞는지 바로 확정할 수 있습니다.
GOLD_ENDPOINT_CANDIDATES = [
    "https://apis.data.go.kr/1160100/GetGeneralProductInfoService_V2/getGoldPriceInfo",
    "https://apis.data.go.kr/1160100/service/GetGeneralProductInfoService_V2/getGoldPriceInfo",
    "https://apis.data.go.kr/1160100/service/GetGeneralProductInfoService/getGoldPriceInfo",
]

# 종가로 쓸 필드 후보들(맞는 게 없으면 실제 키 목록을 로그로 출력합니다)
GOLD_PRICE_FIELD_CANDIDATES = ["clpr", "closePrc", "wghtAvgPrc", "price", "clsprc"]


def _mask_key(text: str, api_key: str) -> str:
    """로그에 인증키가 그대로 찍히지 않도록 가립니다."""
    return text.replace(api_key, "****") if api_key else text


def _parse_items(res_text: str) -> list:
    """응답이 JSON이든 XML이든 item 목록(dict의 list)으로 바꿔 줍니다."""
    # 1) JSON 시도
    try:
        data = json.loads(res_text)
        items = data["response"]["body"]["items"]
        item_list = items["item"] if isinstance(items, dict) else items
        if isinstance(item_list, dict):
            item_list = [item_list]
        return item_list or []
    except Exception:
        pass

    # 2) XML 시도
    try:
        import xml.etree.ElementTree as ET
        root = ET.fromstring(res_text)
        out = []
        for item in root.iter("item"):
            out.append({child.tag: (child.text or "").strip() for child in item})
        return out
    except Exception:
        return []


def fetch_gold_price_per_g(base_date: dt.date, max_lookback_days: int = 10) -> int | None:
    api_key = os.environ.get("GOLD_API_KEY", "")
    if not api_key:
        print("[금현물] GOLD_API_KEY가 설정되어 있지 않습니다. 건너뜁니다.", file=sys.stderr)
        return None

    working_endpoint = None  # 한 번 성공한 주소는 이후 날짜 재시도에서 그대로 재사용

    d = base_date
    for _ in range(max_lookback_days):
        ymd = d.strftime("%Y%m%d")
        params = {
            "serviceKey": api_key,   # data.go.kr 일반 인증키(Decoding 값)
            "resultType": "json",
            "basDt": ymd,            # 날짜 파라미터명이 다르면 이 줄만 고치면 됩니다
            "numOfRows": "10",
            "pageNo": "1",
        }

        endpoints = [working_endpoint] if working_endpoint else GOLD_ENDPOINT_CANDIDATES
        for url in endpoints:
            try:
                res = requests.get(url, params=params, timeout=15)
            except Exception as e:
                print(f"[금현물] 요청 자체 실패 {url}: {e}", file=sys.stderr)
                continue

            snippet = _mask_key(res.text[:300].replace("\n", " "), api_key)
            if working_endpoint is None:
                # 첫 탐색 때만 후보별 결과를 로그로 남깁니다
                print(f"[금현물] 후보 주소 시도 · HTTP {res.status_code} · {url}")
                print(f"         응답 앞부분: {snippet}")

            if res.status_code != 200:
                continue

            item_list = _parse_items(res.text)
            if not item_list:
                # 인증키 오류·휴장일 등도 여기로 옵니다(응답 앞부분 로그로 구분 가능)
                working_endpoint = working_endpoint or url
                break

            working_endpoint = url
            item = item_list[0]
            print(f"[금현물] 응답 항목의 실제 키 목록: {list(item.keys())}")

            for field in GOLD_PRICE_FIELD_CANDIDATES:
                if field in item:
                    try:
                        price = int(round(float(str(item[field]).replace(",", ""))))
                        print(f"[금현물] 기준일 {ymd} · {field}={price}원/g · 주소={url}")
                        return price
                    except Exception:
                        continue

            print(
                "[금현물] 예상한 가격 필드를 못 찾았습니다. 위 '실제 키 목록' 중 "
                "'1g당 종가'에 해당하는 키를 GOLD_PRICE_FIELD_CANDIDATES에 추가해 주세요. "
                f"(항목 전체: {_mask_key(str(item)[:500], api_key)})",
                file=sys.stderr,
            )
            return None

        # 이 날짜로는 데이터를 못 얻었으니 하루 전으로(주말·공휴일 대응)
        print(f"[금현물] {ymd} 데이터 없음, 하루 전으로 재시도")
        d -= dt.timedelta(days=1)

    print("[금현물] 최근 영업일 데이터를 찾지 못했습니다.", file=sys.stderr)
    return None


def fetch_gold_price_per_g_fallback(usdkrw: float | None) -> int | None:
    """
    공공데이터포털 금 API가 실패했을 때를 위한 예비 경로입니다.
    국제 금선물(COMEX, GC=F, 달러/온스)을 원/g으로 환산합니다.
    ⚠️ 이것은 KRX 금시장 종가가 아니라 국제시세 환산 "추정치"이므로,
    prices.json에 source를 따로 남겨서 앱에서 다른 문구로 표시하게 합니다
    (공공데이터 출처 표기를 엉뚱한 데이터에 붙이지 않기 위함).
    """
    if not usdkrw:
        return None
    try:
        import yfinance as yf
        df = yf.download(tickers="GC=F", period="5d", interval="1d", progress=False)
        close = df["Close"].dropna()
        if close.empty:
            return None
        usd_per_oz = float(close.iloc[-1].item() if hasattr(close.iloc[-1], "item") else close.iloc[-1])
        krw_per_g = usd_per_oz / 31.1034768 * usdkrw   # 1트로이온스 = 31.1034768g
        print(f"[금현물-예비] 국제 금선물 {usd_per_oz:.2f}달러/oz → {int(round(krw_per_g))}원/g 환산")
        return int(round(krw_per_g))
    except Exception as e:
        print(f"[금현물-예비] 국제 금시세 환산 실패: {e}", file=sys.stderr)
        return None


# ---------------------------------------------------------------------------
# main
# ---------------------------------------------------------------------------
def main():
    base_date = today_kst()
    print(f"=== 시세 수집 시작: 기준일 {base_date.isoformat()} (KST) ===")

    kr_universe = load_kr_universe()
    kr_prices = fetch_kr_close_prices(kr_universe) if kr_universe else {}

    us_tickers = load_us_universe()
    us_prices = fetch_us_close_prices(us_tickers) if us_tickers else {}

    usdkrw = fetch_usdkrw()

    # 금: 공공데이터포털(KRX 금시장 종가)을 우선 쓰고, 실패하면 국제시세 환산 추정치로 대체
    gold_price = fetch_gold_price_per_g(base_date)
    gold_source = "krx_public_data" if gold_price is not None else None
    if gold_price is None:
        gold_price = fetch_gold_price_per_g_fallback(usdkrw)
        gold_source = "intl_futures_est" if gold_price is not None else None

    output = {
        "date": base_date.isoformat(),
        "kr": kr_prices,
        "us": us_prices,
        "gold_krx": {"price_per_g": gold_price, "source": gold_source} if gold_price is not None else {},
        "fx": {"usdkrw": usdkrw} if usdkrw is not None else {},
    }

    OUTPUT_PATH.write_text(
        json.dumps(output, ensure_ascii=False, separators=(",", ":")),
        encoding="utf-8",
    )
    print(
        f"=== 완료: kr={len(kr_prices)}개, us={len(us_prices)}개, "
        f"gold={'수집됨' if gold_price is not None else '실패'}, "
        f"fx={'수집됨' if usdkrw is not None else '실패'} → {OUTPUT_PATH} ==="
    )


if __name__ == "__main__":
    main()
