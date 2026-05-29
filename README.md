# DDR Custom Assistant — Basket Manager (MT4 / MQL4)

> Expert Advisor MetaTrader 4 untuk **mengelola order yang sudah ada** (basket manager).
> EA ini **tidak membuka posisi baru**. Tugasnya: mengunci profit dengan ATR Stop Loss
> dan **menutup sekelompok order (pair / triple) ketika total profit gabungan** mencapai
> target per-lot.

| | |
|---|---|
| **Versi** | 3.00 (final revision) |
| **Platform** | MetaTrader 4 (MQL4, build 600+) |
| **Tipe** | Expert Advisor (single-file, modular) |
| **Sumber kode** | [`DDR_Custom_Assistant.mq4`](./DDR_Custom_Assistant.mq4) |
| **Status** | Mengelola order existing saja (tidak entry) |

---

## Daftar Isi

1. [Product Requirements Document (PRD)](#1-product-requirements-document-prd)
2. [Blueprint / Technical Design](#2-blueprint--technical-design)
   - [2.1 Arsitektur Modular](#21-arsitektur-modular)
   - [2.2 Alur Eksekusi (OnTick Flow)](#22-alur-eksekusi-ontick-flow)
   - [2.3 Data Dictionary](#23-data-dictionary)
   - [2.4 Use of Files / Used By / Used For](#24-use-of-files--used-by--used-for)
   - [2.5 Design Pattern & Best Practice](#25-design-pattern--best-practice)
3. [Step-by-Step User Guide](#3-step-by-step-user-guide)
4. [Appendix: Changelog & Disclaimer](#4-appendix-changelog--disclaimer)

---

## 1. Product Requirements Document (PRD)

### 1.1 Ringkasan
DDR Custom Assistant adalah **asisten manajemen basket** untuk trader yang menjalankan
strategi grid/hedging di MetaTrader 4. EA memindai seluruh order pada simbol chart aktif,
mengidentifikasi order-order ekstrem (Buy tertinggi/terendah, Sell tertinggi/terendah),
lalu menutupnya secara berkelompok ketika profit gabungannya menguntungkan. EA juga dapat
memasang Stop Loss berbasis ATR pada leg-leg tertentu untuk mengunci profit.

### 1.2 Latar Belakang / Problem Statement
Pada strategi grid/hedging, posisi bisa menumpuk. Menutup order satu per satu secara manual
berisiko: salah leg, salah timing, atau menutup pada total yang belum profit setelah
memperhitungkan spread. EA ini mengotomatiskan keputusan close berbasis **profit gabungan
dalam satuan uang per lot**, sambil tetap menjaga "leg jangkar" (No.1 paling ekstrem) tetap
terbuka untuk strategi tertentu.

### 1.3 Tujuan (Goals)
- **G1** — Menutup pasangan/triple order secara otomatis saat profit gabungan ≥ target.
- **G2** — Memperhitungkan biaya spread agar target close benar-benar net.
- **G3** — Mengunci profit per-leg dengan SL berbasis volatilitas (ATR).
- **G4** — Menyediakan dashboard ringkas (harga leg + profit + spread + ATR).
- **G5** — Eksekusi yang aman: verifikasi tiap close, retry pada error sementara.

### 1.4 Non-Goals (yang TIDAK dilakukan)
- ❌ Tidak membuka order baru (bukan sistem entry).
- ❌ Tidak melakukan money management / position sizing.
- ❌ Tidak memberi sinyal beli/jual atau prediksi arah.
- ❌ Tidak mengelola order di simbol lain selain chart tempat EA dipasang.

### 1.5 Target Pengguna (Persona)
- **Trader grid/hedging** yang sudah punya banyak posisi dan butuh exit otomatis berbasis basket.
- **Manual trader** yang ingin "auto take-profit" pada gabungan beberapa posisi.

### 1.6 Functional Requirements

| ID | Requirement | Acceptance Criteria |
|----|-------------|---------------------|
| FR-1 | Scan semua order pada simbol chart | Hanya order `_Symbol`, sesuai filter magic, tipe Buy/Sell yang diproses |
| FR-2 | Identifikasi order ekstrem No.1 & No.2 | `buyHigh`, `buyLow(No.2)`, `buyLowAbs(No.1)`, `sellLow`, `sellHigh(No.2)`, `sellHighAbs(No.1)` |
| FR-3 | 4 strategi close dapat di-enable/disable terpisah | Tiap strategi punya input `InpEnable_*` |
| FR-4 | Target close berbasis $ per lot + buffer spread | Close hanya jika `totalProfit ≥ targetPerLot × totalLots + spreadCost` |
| FR-5 | ATR Stop Loss (opsional) pada leg non-jangkar | SL di zona profit, jarak `ATR×mult + spread`, hormati StopLevel |
| FR-6 | Eksekusi aman | Verifikasi tiap leg, retry error transient, log hasil & partial close |
| FR-7 | Maksimum 1 basket ditutup per tick | Setelah close, `OnTick` berhenti & re-scan pada tick berikutnya |
| FR-8 | Dashboard on-chart | Menampilkan harga leg, profit per strategi, spread (pips), ATR |
| FR-9 | Lisensi/expiry | EA berhenti & menampilkan pesan jika expired / akun tidak terdaftar |

### 1.7 Non-Functional Requirements

| ID | Aspek | Target |
|----|-------|--------|
| NFR-1 | Keandalan | Retry pada error 129/135/136/138/146 dll.; partial-close di-log |
| NFR-2 | Keamanan eksekusi | Cek `IsTradeAllowed()`, `RefreshRates()`, harga di-`NormalizeDouble` |
| NFR-3 | Kompatibilitas | Broker 3/5-digit (point auto-adjust), build MT4 600+ |
| NFR-4 | Performa | GUI di-throttle (default 1 detik); 1 aksi trade per tick |
| NFR-5 | Keterbacaan | Modular, SRP, named constants, komentar per modul |

### 1.8 Definisi 4 Strategi

| # | Nama | Tipe | Leg yang ditutup | Target default ($/lot) |
|---|------|------|------------------|------------------------|
| 1 | BUY-BUY | PAIR | `buyHigh` + `buyLow(No.2)` | 1.5 |
| 2 | SELL-SELL | PAIR | `sellLow` + `sellHigh(No.2)` | 1.5 |
| 3 | SELL-BUY | TRIPLE | `buyHigh` + `sellHigh(No.2)` + `sellHighAbs(No.1)` | 0.5 |
| 4 | BUY-SELL | TRIPLE | `buyLow(No.2)` + `buyLowAbs(No.1)` + `sellLow` | 0.5 |

> **ATR SL diterapkan ke:** `buyHigh`, `buyLow(No.2)`, `sellLow`, `sellHigh(No.2)`.
> **TIDAK diterapkan ke (jangkar No.1):** `buyLowAbs`, `sellHighAbs`.

### 1.9 Asumsi & Batasan
- Order sudah dibuka oleh trader/EA lain; EA ini hanya mengelola.
- Strategi PAIR efektif bila terdapat **≥ 3 order** di sisi yang sama (leg No.1 jangkar tetap terbuka). Dengan tepat 2 order sisi sama, "No.2" berhimpit dengan leg tertinggi sehingga pair tidak dieksekusi (by design).
- `MarketInfo(MODE_TICKVALUE/MODE_SPREAD)` tersedia & valid dari broker.

### 1.10 Risiko & Mitigasi

| Risiko | Mitigasi |
|--------|----------|
| Leg dipakai >1 strategi → snapshot basi | **1 close per tick** lalu re-scan tick berikutnya |
| Close non-atomik (1 leg gagal) | Verifikasi + retry; partial close di-log & dievaluasi ulang |
| ATR SL ter-trigger sendiri → basket pecah | ATR SL **opsional** (`InpEnableATRStop`) |
| Harga SL ditolak broker (error 130) | `NormalizeDouble` + cek `MODE_STOPLEVEL` |
| Spread melebar saat close | Buffer spread (`InpAddSpreadBuffer`) ditambahkan ke target |

---

## 2. Blueprint / Technical Design

### 2.1 Arsitektur Modular
Satu file `.mq4`, disusun sebagai modul-modul independen (modular monolith). Setiap modul
punya satu tanggung jawab (Single Responsibility).

```
┌───────────────────────────────────────────────────────────┐
│                    LIFECYCLE (entry point)                  │
│              OnInit() · OnTick() · OnDeinit()               │
└───────────────┬───────────────────────────┬───────────────┘
                │                           │
        ┌───────▼────────┐          ┌───────▼────────┐
        │   License      │          │     GUI         │
        │  License_Check │          │  Gui_Build/...  │
        └────────────────┘          └────────────────┘
                │
        ┌───────▼────────┐   menghasilkan   ┌────────────────┐
        │   Scanner       │ ───────────────▶ │  ScanResult     │
        │  Scanner_Run    │                  │ (6x OrderState) │
        └───────┬────────┘                  └───────┬────────┘
                │                                   │
        ┌───────▼─────────┐                ┌────────▼─────────┐
        │  ATR Stop Loss  │                │     Closer       │
        │  Atr_ApplyAll   │                │ Strategies_Run   │
        └───────┬─────────┘                └────────┬─────────┘
                │                                   │
                └──────────────┬────────────────────┘
                       ┌───────▼────────┐
                       │  Trade Wrapper │  (Facade/Adapter)
                       │ CloseTicket /  │
                       │ ModifyStopLoss │
                       └───────┬────────┘
                       ┌───────▼────────┐
                       │  Pricing /     │
                       │  Logger        │
                       └────────────────┘
```

### 2.2 Alur Eksekusi (OnTick Flow)

```
OnTick()
  1. License_Check() ───────────────► gagal? STOP (tampilkan Comment)
  2. RefreshRates()                   (ambil harga terbaru)
  3. Scanner_Run(r) ────────────────► hasil: ScanResult r (6 leg ekstrem)
  4. Atr_ApplyAll(r) ───────────────► (jika InpEnableATRStop) pasang SL profit-lock
  5. Gui_MaybeUpdate(r) ────────────► update dashboard (throttle InpGuiUpdateSecs)
  6. Strategies_Run(r) ─────────────► evaluasi S1..S4 berurutan;
                                       tutup MAKS 1 basket lalu return
                                       → tick berikutnya re-scan fresh
```

**Rumus keputusan close** (per basket):
```
spreadCost  = InpAddSpreadBuffer ? (MODE_SPREAD × MODE_TICKVALUE × totalLots) : 0
targetMoney = targetPerLot × totalLots + spreadCost
CLOSE bila:  totalProfit (net: profit+komisi+swap)  ≥  targetMoney
```

**Rumus ATR Stop Loss** (leg non-jangkar):
```
slDist = InpATR_Multiplier × ATR(prev bar) + (Ask − Bid)
Buy  : newSL = NormalizeDouble(openPrice + slDist)
Sell : newSL = NormalizeDouble(openPrice − slDist)
Syarat pasang: jarak ke pasar ≥ MODE_STOPLEVEL  DAN  hanya mengetat (ratchet)
```

### 2.3 Data Dictionary

#### A. Inputs (parameter pengguna)

| Nama | Tipe | Default | Satuan | Deskripsi |
|------|------|---------|--------|-----------|
| `InpMagicNumber` | int | `0` | — | Filter magic number. `0` = semua order pada simbol |
| `InpSlippagePts` | int | `30` | points | Toleransi slippage saat `OrderClose` |
| `InpGuiUpdateSecs` | int | `1` | detik | Interval refresh dashboard |
| `InpRetryCount` | int | `3` | kali | Jumlah percobaan ulang saat error transient |
| `InpRetryDelayMs` | int | `200` | ms | Jeda antar retry (hanya akun live) |
| `InpAddSpreadBuffer` | bool | `true` | — | Tambahkan biaya spread sebagai buffer ke target |
| `InpEnable_BB` | bool | `true` | — | Aktifkan strategi 1 (BUY-BUY) |
| `InpProfit_BB` | double | `1.5` | $/lot | Target profit strategi 1 |
| `InpEnable_SS` | bool | `true` | — | Aktifkan strategi 2 (SELL-SELL) |
| `InpProfit_SS` | double | `1.5` | $/lot | Target profit strategi 2 |
| `InpEnable_SB` | bool | `true` | — | Aktifkan strategi 3 (SELL-BUY) |
| `InpProfit_SB` | double | `0.5` | $/lot | Target profit strategi 3 |
| `InpEnable_BS` | bool | `true` | — | Aktifkan strategi 4 (BUY-SELL) |
| `InpProfit_BS` | double | `0.5` | $/lot | Target profit strategi 4 |
| `InpEnableATRStop` | bool | `true` | — | Aktifkan ATR profit-lock SL |
| `InpATR_Period` | int | `14` | bar | Periode ATR |
| `InpATR_Timeframe` | ENUM_TIMEFRAMES | `PERIOD_H1` | — | Timeframe ATR |
| `InpATR_Multiplier` | double | `1.0` | × | Pengali ATR untuk jarak SL |

#### B. Konstanta

| Nama | Tipe | Nilai | Deskripsi |
|------|------|-------|-----------|
| `LIC_ACCOUNT_ID` | const int | `0` | ID akun berlisensi (`0` = semua akun) |
| `LIC_EXPIRE_DATE` | const string | `"2026.12.01"` | Tanggal kedaluwarsa (YYYY.MM.DD) |
| `GUI_FONT_SZ` | #define | `11` | Ukuran font label (macro karena dipakai default-arg) |
| `GUI_PREFIX` | const string | `"DDR_"` | Prefix nama objek chart |
| `GUI_X_LEFT` / `GUI_X_RIGHT` | const int | `20` / `280` | Posisi X kolom kiri/kanan |
| `GUI_LINE_H` / `GUI_GROUP_H` | const int | `20` / `30` | Tinggi baris / antar grup (px) |
| `GUI_FONT` | const string | `"Consolas"` | Font dashboard |
| `LOG_PREFIX` | const string | `"[DDR] "` | Prefix log `Print()` |

#### C. State Global (runtime)

| Nama | Tipe | Deskripsi |
|------|------|-----------|
| `g_PointAdj` | double | Point ter-normalisasi (×10 untuk broker 3/5-digit) untuk tampilan pips |
| `g_ExpireTs` | datetime | Timestamp hasil parse `LIC_EXPIRE_DATE` |
| `g_LastGuiTs` | datetime | Timestamp update GUI terakhir (untuk throttle) |

#### D. Struct `OrderState` (Data Transfer Object)

| Field | Tipe | Deskripsi |
|-------|------|-----------|
| `ticket` | int | Nomor tiket order; `-1` = kosong/sentinel |
| `price` | double | Harga open order (atau seed `0`/`DBL_MAX` saat reset) |
| `lots` | double | Volume lot |
| `profit` | double | Profit **net** = `OrderProfit + Commission + Swap` |
| `type` | int | `OP_BUY` / `OP_SELL` |
| `IsValid()` | method→bool | `true` bila `ticket != -1` |

#### E. Struct `ScanResult` (hasil pemindaian)

| Field | Makna | Seed awal |
|-------|-------|-----------|
| `buyHigh` | Buy harga tertinggi | `price = 0` |
| `buyLow` | Buy terendah ke-2 (No.2 / runner-up) | `price = DBL_MAX` |
| `buyLowAbs` | Buy terendah (No.1 / jangkar) | `price = DBL_MAX` |
| `sellLow` | Sell harga terendah | `price = DBL_MAX` |
| `sellHigh` | Sell tertinggi ke-2 (No.2 / runner-up) | `price = 0` |
| `sellHighAbs` | Sell tertinggi (No.1 / jangkar) | `price = 0` |

### 2.4 Use of Files / Used By / Used For

#### Berkas dalam repository

| File | Use of file (isi) | Used by | Used for |
|------|-------------------|---------|----------|
| `DDR_Custom_Assistant.mq4` | Seluruh source EA (single-file modular) | MetaEditor (compile → `.ex4`), MT4 terminal | Menjalankan basket manager pada chart |
| `README.md` | Dokumentasi (PRD, blueprint, data dictionary, guide) | Developer / pengguna | Memahami, memasang, & memelihara EA |

#### Modul internal dalam `DDR_Custom_Assistant.mq4`

| # | Modul | Fungsi utama | Used by | Used for |
|---|-------|--------------|---------|----------|
| 3 | **Logger** | `Log()` | Semua modul | Output diagnostik berprefix `[DDR]` |
| 4 | **Trade Wrapper** | `Trade_IsRetryableError`, `Trade_Pause`, `Trade_CloseTicket`, `Trade_ModifyStopLoss` | Closer, ATR | Eksekusi `OrderClose`/`OrderModify` aman + retry |
| 5 | **OrderState** | `OrderState_Reset`, `OrderState_FillFromCurrent`, `IsValid` | Scanner, ATR, Closer, GUI | Membawa data 1 order antar modul |
| 6 | **Scanner** | `Scanner_Init/PassesFilter/HandleBuy/HandleSell/Run` | Lifecycle (`OnTick`) | Menemukan 6 leg ekstrem → `ScanResult` |
| 7 | **Pricing** | `Spread_PriceDelta`, `Spread_CostMoney` | ATR, Closer, GUI | Hitung selisih & biaya spread |
| 8 | **ATR Stop Loss** | `Atr_Value/StopLevelDist/NeedsModifyBuy/NeedsModifySell/ApplyTo/ApplyAll` | Lifecycle (`OnTick`) | Pasang SL profit-lock di leg non-jangkar |
| 9 | **Closer** | `Closer_DistinctValid2/3`, `Closer_CloseBasket`, `Closer_TryPair/TryTriple`, `Strategies_Run` | Lifecycle (`OnTick`) | Evaluasi & tutup basket (maks 1/tick) |
| 10 | **License** | `License_Check` | Lifecycle (`OnTick`) | Gating expiry / akun |
| 11 | **GUI** | `Gui_CreateLabel/SetText/SetColor/Build/Update/MaybeUpdate/Destroy/PriceText/SetProfit` | Lifecycle (semua) | Dashboard on-chart |
| 12 | **Lifecycle** | `OnInit`, `OnTick`, `OnDeinit` | MT4 terminal | Titik masuk EA (init/tick/cleanup) |

### 2.5 Design Pattern & Best Practice

| Pattern / Praktik | Penerapan di kode | Manfaat |
|-------------------|-------------------|---------|
| **Facade / Adapter** | `Trade_CloseTicket`, `Trade_ModifyStopLoss` membungkus API mentah `OrderClose`/`OrderModify` | API trading konsisten, error handling terpusat |
| **Strategy Pattern** | 4 strategi (BB/SS/SB/BS) dievaluasi seragam via `Closer_TryPair/TryTriple` di `Strategies_Run` | Tambah/nonaktifkan strategi tanpa ubah inti |
| **Data Transfer Object / Value Object** | `OrderState`, `ScanResult` | Pemindahan data antar modul rapi & eksplisit |
| **Null Object / Sentinel** | `ticket = -1` + seed `DBL_MAX`/`0` + `IsValid()` | Hindari null-check tersebar; perbandingan ekstrem aman |
| **Single Responsibility (SRP)** | Tiap modul satu tugas (Scanner, Closer, ATR, GUI, …) | Mudah dibaca, diuji, dipelihara |
| **Guard Clauses (early return)** | `if(!valid) return;` di hampir semua fungsi | Mengurangi nesting, alur jelas |
| **Snapshot + Single-Action-per-Tick** | `Strategies_Run` tutup **1 basket/tick** lalu return | Mencegah keputusan atas state basi (leg dipakai >1 strategi) |
| **Retry / Resilience (transient fault handling)** | `Trade_IsRetryableError` + loop `InpRetryCount` + `Trade_Pause` | Tahan requote/off-quotes/context-busy |
| **Ratchet / Monotonic update** | `Atr_NeedsModifyBuy/Sell` hanya izinkan SL mengetat | SL tidak pernah dilonggarkan |
| **Throttling / Rate limiting** | `Gui_MaybeUpdate` pakai `InpGuiUpdateSecs` | Hemat CPU & redraw |
| **Fail-safe defaults + Validation** | `OnInit` validasi parameter → `INIT_PARAMETERS_INCORRECT` | Cegah konfigurasi invalid sejak awal |
| **Pure functions (testable)** | `Atr_NeedsModifyBuy/Sell`, `Closer_DistinctValid2/3` | Logika murni tanpa efek samping, mudah dinalar |
| **Named Constants (no magic numbers)** | Bagian Konstanta + grup Inputs | Konfigurasi terpusat & terbaca |

---

## 3. Step-by-Step User Guide

### 3.1 Prasyarat
- Terminal **MetaTrader 4** (build 600+).
- Akun dengan posisi yang ingin dikelola (EA tidak membuka posisi).
- File [`DDR_Custom_Assistant.mq4`](./DDR_Custom_Assistant.mq4).

### 3.2 Instalasi
1. Buka MT4 → menu **File → Open Data Folder**.
2. Masuk ke folder `MQL4/Experts/`.
3. Salin `DDR_Custom_Assistant.mq4` ke folder tersebut.
4. Buka **MetaEditor** (F4) → buka file → klik **Compile** (F7). Pastikan **0 error**.
   (File `DDR_Custom_Assistant.ex4` akan terbentuk.)
5. Kembali ke MT4 → klik **Refresh** pada panel **Navigator → Expert Advisors**.

### 3.3 Memasang ke Chart
1. Buka chart simbol yang ingin dikelola (mis. `XAUUSD`).
2. Drag **DDR Custom Assistant** dari Navigator ke chart.
3. Pada tab **Common**, centang **Allow live trading** (dan **Allow DLL** tidak diperlukan).
4. Pastikan tombol **AutoTrading** (toolbar) menyala (hijau).
5. Klik **OK** — dashboard `DDR_` akan muncul di pojok kiri-atas chart.

### 3.4 Mengatur Parameter (tab Inputs)
- **General**: set `InpMagicNumber` ke `0` untuk mengelola semua order simbol, atau ke magic tertentu agar selektif. Atur `InpSlippagePts` sesuai broker.
- **Strategy 1–4**: aktif/nonaktif lewat `InpEnable_*`, dan set target `$ per lot` lewat `InpProfit_*`.
- **Spread buffer**: biarkan `InpAddSpreadBuffer = true` agar target sudah net terhadap spread.
- **ATR Stop Loss**: set `InpEnableATRStop`. Jika Anda **tidak ingin** SL per-leg memecah basket, set `false`.

### 3.5 Membaca Dashboard
```
Spread: 1.8 pips
ATR x1.00: 0.00350

STRATEGY 1: BUY-BUY          STRATEGY 3: SELL-BUY
Buy  High  : 1.23456         Buy  High  : 1.23456
Buy  Lo(2) : 1.23001         Sell Hi(2) : 1.24500
Profit     : $3.20  (hijau)  Sell Hi(1) : 1.24900
                             Profit     : $1.10
STRATEGY 2: SELL-SELL
Sell Low   : 1.22000         STRATEGY 4: BUY-SELL
Sell Hi(2) : 1.24500         Buy  Lo(2) : 1.23001
Profit     : -$0.50 (merah)  Buy  Lo(1) : 1.22800
                             Sell Low   : 1.22000
                             Profit     : $0.40
```
- **Profit hijau** = ≥ 0, **merah** = < 0.
- `N/A` berarti leg yang dibutuhkan strategi belum ada.

### 3.6 Cara Kerja Saat Berjalan
1. Setiap tick EA memindai order, (opsional) memasang ATR SL, lalu mengecek tiap strategi.
2. Begitu satu basket memenuhi target, **basket itu ditutup** dan EA berhenti untuk tick ini.
3. Pada tick berikutnya EA memindai ulang kondisi terbaru — sehingga aman walau leg dipakai beberapa strategi.

### 3.7 Logging & Troubleshooting
Cek tab **Experts** (dan **Journal**) di MT4. Contoh log berprefix `[DDR]`:
- `Basket BUY-BUY | closed 2/2 | profit=3.20 target=3.05 ...` → sukses.
- `WARNING: basket ... partially closed (1/2)` → 1 leg gagal; akan dievaluasi ulang tick berikutnya.
- `ATR SL set BUY ticket=... sl=...` → SL terpasang.
- `Close: trading not allowed` → aktifkan AutoTrading / Allow live trading.

| Gejala | Kemungkinan sebab | Solusi |
|--------|-------------------|--------|
| Tidak ada yang ditutup | Profit belum capai target, atau leg kurang | Cek dashboard; pastikan ≥3 order untuk strategi PAIR |
| EA tidak trading | AutoTrading off / live trading off | Nyalakan AutoTrading & centang Allow live trading |
| SL tidak terpasang | Profit belum cukup jauh (StopLevel) / ATR=0 | Tunggu profit cukup; cek data bar untuk ATR |
| Pesan "EA EXPIRED" | Lewat `LIC_EXPIRE_DATE` | Hubungi admin untuk update |

### 3.8 Menghentikan / Uninstall
- **Sementara**: matikan **AutoTrading**, atau hapus EA dari chart (label `DDR_` otomatis terhapus saat `OnDeinit`).
- **Permanen**: hapus `DDR_Custom_Assistant.mq4`/`.ex4` dari `MQL4/Experts/`.

> ⚠️ **Uji dulu di akun demo / Strategy Tester** sebelum dipakai di akun real.

---

## 4. Appendix: Changelog & Disclaimer

### Changelog (v2.0 → v3.0)
- **Fix** snapshot basi pada leg yang dipakai banyak strategi → **maks 1 close/tick** lalu re-scan.
- **Fix** close non-atomik → verifikasi tiap leg + **retry** error transient + log partial close.
- **Fix** harga SL kini di-`NormalizeDouble`.
- **New** ATR Stop Loss dijadikan **opsional** (`InpEnableATRStop`).
- **New** buffer spread dijadikan **opsional & eksplisit** (`InpAddSpreadBuffer`).
- **New** input `InpRetryCount`, `InpRetryDelayMs`; validasi parameter di `OnInit`.
- **Refactor** Trade wrapper (Facade), penamaan konsisten, hapus dead code, komentar dirapikan.

### Disclaimer
Perangkat lunak ini disediakan "apa adanya", tanpa jaminan. Trading mengandung risiko
kehilangan modal. Selalu uji di akun demo terlebih dahulu. Penggunaan pada akun real adalah
tanggung jawab pengguna sepenuhnya.

---
*Copyright © 2024 — Kontak: https://wa.me/+628811230359*
