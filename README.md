# DDR Custom Assistant — Basket Manager (MT4 / MQL4)

> Expert Advisor MetaTrader 4 untuk **mengelola order yang sudah ada** (basket manager).
> EA ini **tidak membuka posisi baru**. Tugasnya: mengunci profit dengan ATR Stop Loss
> dan **menutup sekelompok order (pair / triple) ketika total profit gabungan** mencapai
> target per-lot.

| | |
|---|---|
| **Versi** | 4.00 (final revision) |
| **Platform** | MetaTrader 4 (MQL4, build 600+) |
| **Tipe** | Expert Advisor (single-file, modular) |
| **Sumber kode** | [`DDR_Custom_Assistant.mq4`](./DDR_Custom_Assistant.mq4) |
| **Status** | Mengelola order existing saja (tidak entry) |

> **Catatan v4.0** — Strategi 3 & 4 kini bekerja pada **lapisan dalam (inner layers)**
> menggunakan ekstrem ke-2 & ke-3, sementara ekstrem ke-1 (`Buy Lo(1)` / `Sell Hi(1)`)
> dipertahankan sebagai **anchor display-only** (tidak pernah ditutup otomatis).

---

## Daftar Isi

1. [Product Requirements Document (PRD)](#1-product-requirements-document-prd)
2. [Blueprint / Technical Design](#2-blueprint--technical-design)
   - [2.1 Arsitektur Modular](#21-arsitektur-modular)
   - [2.2 Alur Eksekusi (OnTick Flow)](#22-alur-eksekusi-ontick-flow)
   - [2.3 Data Dictionary](#23-data-dictionary)
   - [2.4 Use of Objects/Functions — Used By / Used For](#24-use-of-objectsfunctions--used-by--used-for)
   - [2.5 Design Pattern & Best Practice](#25-design-pattern--best-practice)
3. [Step-by-Step User Guide](#3-step-by-step-user-guide)
4. [Appendix: Changelog & Disclaimer](#4-appendix-changelog--disclaimer)

---

## 1. Product Requirements Document (PRD)

### 1.1 Ringkasan
DDR Custom Assistant adalah **asisten manajemen basket** untuk trader yang menjalankan
strategi grid/hedging di MetaTrader 4. EA memindai seluruh order pada simbol chart aktif,
mengurutkan order-order ekstrem (3 Buy terendah, 3 Sell tertinggi, plus Buy tertinggi &
Sell terendah), lalu menutupnya secara berkelompok ketika profit gabungannya menguntungkan.
EA juga memasang Stop Loss berbasis ATR pada leg kerja untuk mengunci profit.

### 1.2 Latar Belakang / Problem Statement
Pada strategi grid/hedging, posisi mudah menumpuk. Menutup order satu per satu secara manual
berisiko: salah leg, salah timing, atau menutup pada total yang belum profit setelah dikurangi
spread. EA ini mengotomatiskan keputusan close berbasis **profit gabungan dalam satuan uang
per lot**, sambil menjaga "leg jangkar" (ekstrem No.1) tetap terbuka sebagai hedge.

### 1.3 Tujuan (Goals)
- **G1** — Menutup pasangan/triple order otomatis saat profit gabungan ≥ target.
- **G2** — Memperhitungkan biaya spread agar target close benar-benar net.
- **G3** — Mengunci profit per-leg dengan SL berbasis volatilitas (ATR).
- **G4** — Mempertahankan ekstrem No.1 sebagai anchor (tidak ditutup otomatis).
- **G5** — Dashboard ringkas (harga leg + anchor + profit + spread + ATR).
- **G6** — Eksekusi aman: verifikasi tiap close, retry pada error sementara.

### 1.4 Non-Goals (yang TIDAK dilakukan)
- ❌ Tidak membuka order baru (bukan sistem entry).
- ❌ Tidak melakukan money management / position sizing.
- ❌ Tidak memberi sinyal beli/jual atau prediksi arah.
- ❌ Tidak menutup anchor `Lo(1)` / `Hi(1)` secara otomatis.
- ❌ Tidak mengelola order di simbol lain selain chart tempat EA dipasang.

### 1.5 Target Pengguna (Persona)
- **Trader grid/hedging** yang sudah punya banyak posisi dan butuh exit otomatis berbasis basket.
- **Manual trader** yang ingin "auto take-profit" pada gabungan beberapa posisi inner-layer.

### 1.6 Functional Requirements

| ID | Requirement | Acceptance Criteria |
|----|-------------|---------------------|
| FR-1 | Scan semua order pada simbol chart | Hanya order `_Symbol`, sesuai filter magic, tipe Buy/Sell yang diproses |
| FR-2 | Urutkan ekstrem top-3 per sisi | `buyLow[1..3]` = Lo(1..3); `sellHigh[1..3]` = Hi(1..3); plus `buyHigh`, `sellLow` |
| FR-3 | 4 strategi close dapat di-enable/disable terpisah | Tiap strategi punya input `InpEnable_*` |
| FR-4 | Target close berbasis $ per lot + buffer spread | Close hanya jika `totalProfit ≥ targetPerLot × totalLots + spreadCost` |
| FR-5 | Anchor No.1 display-only | `Lo(1)` & `Hi(1)` ditampilkan, tidak pernah ditutup oleh strategi |
| FR-6 | ATR Stop Loss (opsional) pada leg kerja | Diterapkan ke `buyHigh, sellLow, Lo(2), Lo(3), Hi(2), Hi(3)` |
| FR-7 | Eksekusi aman | Verifikasi tiap leg, retry error transient, log hasil & partial close |
| FR-8 | Maksimum 1 basket ditutup per tick | Setelah close, `OnTick` berhenti & re-scan pada tick berikutnya |
| FR-9 | Dashboard on-chart | Spread, ATR, anchors, harga leg & profit per strategi |
| FR-10 | Lisensi/expiry | EA berhenti & menampilkan pesan jika expired / akun tidak terdaftar |

### 1.7 Non-Functional Requirements

| ID | Aspek | Target |
|----|-------|--------|
| NFR-1 | Keandalan | Retry pada error 129/135/136/138/146 dll.; partial-close di-log |
| NFR-2 | Keamanan eksekusi | Cek `IsTradeAllowed()`, `RefreshRates()`, harga di-`NormalizeDouble` |
| NFR-3 | Kompatibilitas | Broker 3/5-digit (point auto-adjust), build MT4 600+ |
| NFR-4 | Performa | GUI di-throttle (default 1 detik); 1 aksi trade per tick |
| NFR-5 | Keterbacaan & ekstensibilitas | Scanner top-N tergeneralisasi (insertion sort); SRP; accessor publik |

### 1.8 Definisi 4 Strategi (v4.0)

| # | Nama | Tipe | Leg yang ditutup | Target ($/lot) |
|---|------|------|------------------|----------------|
| 1 | BUY-BUY | PAIR | `buyHigh` + `Lo(2)` | 0.5 |
| 2 | SELL-SELL | PAIR | `sellLow` + `Hi(2)` | 0.5 |
| 3 | SELL-BUY | TRIPLE | `Lo(2)` + `Hi(2)` + `Hi(3)` | 0.5 |
| 4 | BUY-SELL | TRIPLE | `Lo(2)` + `Lo(3)` + `Hi(2)` | 0.5 |

> **Anchor (display-only, tidak ditutup):** `Lo(1)` (Buy terendah), `Hi(1)` (Sell tertinggi).
> **ATR SL diterapkan ke:** `buyHigh`, `sellLow`, `Lo(2)`, `Lo(3)`, `Hi(2)`, `Hi(3)`.

### 1.9 Asumsi & Batasan (Minimum Order)
EA hanya mengelola order yang sudah ada. Tiap strategi butuh jumlah order minimum agar
leg-nya valid & berbeda tiket:

| Strategi | Minimum order |
|----------|---------------|
| S1 BUY-BUY | **≥ 3 Buy** (agar `buyHigh` ≠ `Lo(2)`) |
| S2 SELL-SELL | **≥ 3 Sell** (agar `sellLow` ≠ `Hi(2)`) |
| S3 SELL-BUY | **≥ 2 Buy & ≥ 3 Sell** |
| S4 BUY-SELL | **≥ 3 Buy & ≥ 2 Sell** |

### 1.10 Risiko & Mitigasi

| Risiko | Mitigasi |
|--------|----------|
| Leg dipakai >1 strategi (mis. `Lo(2)` di S1/S3/S4) → snapshot basi | **1 close per tick** lalu re-scan tick berikutnya |
| Close non-atomik (1 leg gagal) | Verifikasi + retry; partial close di-log & dievaluasi ulang |
| ATR SL ter-trigger sendiri → basket pecah | ATR SL **opsional** (`InpEnableATRStop`) |
| Anchor No.1 menumpuk (tak pernah ditutup) | By design (hedge); pantau margin secara manual |
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
        ┌───────▼────────┐  menghasilkan   ┌────────────────────┐
        │   Scanner       │ ──────────────▶ │  ScanResult         │
        │  Scanner_Run    │                 │ buyHigh, sellLow,   │
        │  +InsertSorted  │                 │ buyLow[3],sellHigh[3]│
        └───────┬────────┘                 └───────┬────────────┘
                │            accessors BuyLo()/SellHi()
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
  3. Scanner_Run(r) ────────────────► ScanResult r (top-3 per sisi + 2 single)
  4. Atr_ApplyAll(r) ───────────────► (jika InpEnableATRStop) SL ke leg kerja (bukan anchor)
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

**Rumus ATR Stop Loss** (leg kerja, bukan anchor):
```
slDist = InpATR_Multiplier × ATR(prev bar) + (Ask − Bid)
Buy  : newSL = NormalizeDouble(openPrice + slDist)
Sell : newSL = NormalizeDouble(openPrice − slDist)
Syarat pasang: jarak ke pasar ≥ MODE_STOPLEVEL  DAN  hanya mengetat (ratchet)
```

**Pemetaan index list (1-based via accessor):**
```
buyLow[0] = Lo(1) anchor    sellHigh[0] = Hi(1) anchor
buyLow[1] = Lo(2)           sellHigh[1] = Hi(2)
buyLow[2] = Lo(3)           sellHigh[2] = Hi(3)
BuyLo(r,n)  -> r.buyLow[n-1]      SellHi(r,n) -> r.sellHigh[n-1]
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
| `InpEnable_BB` | bool | `true` | — | Aktifkan S1 (BUY-BUY): `buyHigh + Lo(2)` |
| `InpProfit_BB` | double | `0.5` | $/lot | Target profit S1 |
| `InpEnable_SS` | bool | `true` | — | Aktifkan S2 (SELL-SELL): `sellLow + Hi(2)` |
| `InpProfit_SS` | double | `0.5` | $/lot | Target profit S2 |
| `InpEnable_SB` | bool | `true` | — | Aktifkan S3 (SELL-BUY): `Lo(2) + Hi(2) + Hi(3)` |
| `InpProfit_SB` | double | `0.5` | $/lot | Target profit S3 |
| `InpEnable_BS` | bool | `true` | — | Aktifkan S4 (BUY-SELL): `Lo(2) + Lo(3) + Hi(2)` |
| `InpProfit_BS` | double | `0.5` | $/lot | Target profit S4 |
| `InpEnableATRStop` | bool | `true` | — | Aktifkan ATR profit-lock SL |
| `InpATR_Period` | int | `14` | bar | Periode ATR |
| `InpATR_Timeframe` | ENUM_TIMEFRAMES | `PERIOD_H1` | — | Timeframe ATR |
| `InpATR_Multiplier` | double | `1.0` | × | Pengali ATR untuk jarak SL |

#### B. Konstanta

| Nama | Tipe | Nilai | Deskripsi |
|------|------|-------|-----------|
| `TOPN` | #define | `3` | Jumlah ekstrem yang dilacak per sisi (Lo/Hi 1..3) |
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

#### E. Struct `ScanResult` (hasil pemindaian, top-3)

| Field | Tipe | Makna |
|-------|------|-------|
| `buyHigh` | OrderState | Buy harga tertinggi (leg S1) |
| `buyLow[0]` | OrderState | `Lo(1)` — Buy terendah (**anchor**, display-only) |
| `buyLow[1]` | OrderState | `Lo(2)` — Buy terendah ke-2 |
| `buyLow[2]` | OrderState | `Lo(3)` — Buy terendah ke-3 |
| `sellLow` | OrderState | Sell harga terendah (leg S2) |
| `sellHigh[0]` | OrderState | `Hi(1)` — Sell tertinggi (**anchor**, display-only) |
| `sellHigh[1]` | OrderState | `Hi(2)` — Sell tertinggi ke-2 |
| `sellHigh[2]` | OrderState | `Hi(3)` — Sell tertinggi ke-3 |

### 2.4 Use of Objects/Functions — Used By / Used For

#### Berkas dalam repository

| File | Use of file (isi) | Used by | Used for |
|------|-------------------|---------|----------|
| `DDR_Custom_Assistant.mq4` | Seluruh source EA (single-file modular) | MetaEditor (compile → `.ex4`), MT4 terminal | Menjalankan basket manager pada chart |
| `README.md` | Dokumentasi (PRD, blueprint, data dictionary, guide) | Developer / pengguna | Memahami, memasang, & memelihara EA |

#### Objek & fungsi inti (per modul)

| Modul | Objek / Fungsi | Used by | Used for |
|-------|----------------|---------|----------|
| **Logger** | `Log()` | Semua modul | Output diagnostik berprefix `[DDR]` |
| **Trade Wrapper** | `Trade_IsRetryableError`, `Trade_Pause`, `Trade_CloseTicket`, `Trade_ModifyStopLoss` | Closer, ATR | Eksekusi `OrderClose`/`OrderModify` aman + retry |
| **OrderState** (struct) | `OrderState_Reset`, `OrderState_FillFromCurrent`, `IsValid()` | Scanner, ATR, Closer, GUI | Membawa data 1 order antar modul |
| **ScanResult** (struct) | `buyHigh`, `buyLow[3]`, `sellLow`, `sellHigh[3]` | Scanner (tulis); ATR/Closer/GUI (baca) | Menyimpan ekstrem top-3 per sisi |
| **Accessors** | `BuyLo(r,n)`, `SellHi(r,n)` | GUI, dokumentasi/API | Akses 1-based ke `Lo(n)`/`Hi(n)` (return copy, read-only) |
| **Scanner** | `Scanner_Init/PassesFilter/InsertSorted/HandleBuy/HandleSell/Run` | Lifecycle (`OnTick`) | Mengisi `ScanResult` via insertion-sort top-N |
| **Pricing** | `Spread_PriceDelta`, `Spread_CostMoney` | ATR, Closer, GUI | Hitung selisih & biaya spread |
| **ATR Stop Loss** | `Atr_Value/StopLevelDist/NeedsModifyBuy/NeedsModifySell/ApplyTo/ApplyAll` | Lifecycle (`OnTick`) | Pasang SL profit-lock di leg kerja (bukan anchor) |
| **Closer** | `Closer_DistinctValid2/3`, `Closer_CloseBasket`, `Closer_TryPair/TryTriple`, `Strategies_Run` | Lifecycle (`OnTick`) | Evaluasi & tutup basket (maks 1/tick) |
| **License** | `License_Check` | Lifecycle (`OnTick`) | Gating expiry / akun |
| **GUI** | `Gui_CreateLabel/SetText/SetColor/Build/Update/MaybeUpdate/Destroy/PriceText/SetProfit` | Lifecycle (semua) | Dashboard on-chart (anchors + 4 strategi) |
| **Lifecycle** | `OnInit`, `OnTick`, `OnDeinit` | MT4 terminal | Titik masuk EA (init/tick/cleanup) |

### 2.5 Design Pattern & Best Practice

| Pattern / Praktik | Penerapan di kode | Manfaat |
|-------------------|-------------------|---------|
| **Facade / Adapter** | `Trade_CloseTicket`, `Trade_ModifyStopLoss` membungkus API mentah `OrderClose`/`OrderModify` | API trading konsisten, error handling terpusat |
| **Strategy Pattern** | 4 strategi (BB/SS/SB/BS) dievaluasi seragam via `Closer_TryPair/TryTriple` di `Strategies_Run` | Tambah/nonaktifkan strategi tanpa ubah inti |
| **Top-N Selection (Insertion Sort)** | `Scanner_InsertSorted` menjaga list terurut top-3; generik via flag `keepLowest` | Mudah menambah `No.N` baru; logika ekstrem terpusat & teruji |
| **Accessor / Encapsulation** | `BuyLo(r,n)` / `SellHi(r,n)` (1-based) | Sembunyikan index array 0-based; pemanggil tetap terbaca |
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
| **Named Constants (no magic numbers)** | `TOPN`, bagian Konstanta + grup Inputs | Konfigurasi terpusat & terbaca |

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
5. Kembali ke MT4 → klik kanan **Navigator → Expert Advisors → Refresh**.

### 3.3 Memasang ke Chart
1. Buka chart simbol yang ingin dikelola (mis. `XAUUSD`).
2. Drag **DDR Custom Assistant** dari Navigator ke chart.
3. Pada tab **Common**, centang **Allow live trading**.
4. Pastikan tombol **AutoTrading** (toolbar) menyala (hijau).
5. Klik **OK** — dashboard `DDR_` muncul di pojok kiri-atas chart.

### 3.4 Mengatur Parameter (tab Inputs)
- **General**: set `InpMagicNumber` ke `0` untuk semua order simbol, atau magic tertentu agar selektif. Sesuaikan `InpSlippagePts`.
- **Strategy 1–4**: aktif/nonaktif via `InpEnable_*`; target default `0.5 $/lot` (`InpProfit_*`).
- **Spread buffer**: biarkan `InpAddSpreadBuffer = true` agar target sudah net terhadap spread.
- **ATR Stop Loss**: set `InpEnableATRStop`. Jika tidak ingin SL per-leg memecah basket, set `false`.

### 3.5 Memahami Anchor vs Leg Kerja
- **Anchor** = `Buy Lo(1)` (Buy paling rendah) & `Sell Hi(1)` (Sell paling tinggi).
  Ditampilkan di bagian **ANCHORS (hold)**, **tidak pernah ditutup otomatis** dan **tidak** dipasangi ATR SL — berfungsi sebagai hedge.
- **Leg kerja** = `Lo(2)`, `Lo(3)`, `Hi(2)`, `Hi(3)`, plus `buyHigh` & `sellLow` — inilah yang dikombinasikan oleh strategi & dipasangi ATR SL.

### 3.6 Membaca Dashboard
```
Spread: 1.8 pips
ATR x1.00: 0.00350
ANCHORS (hold):
Buy  Lo(1) : 1.22800
Sell Hi(1) : 1.24900

STRATEGY 1: BUY-BUY          STRATEGY 3: SELL-BUY
Buy  High  : 1.23456         Buy  Lo(2) : 1.23001
Buy  Lo(2) : 1.23001         Sell Hi(2) : 1.24500
Profit     : $0.80 (hijau)   Sell Hi(3) : 1.24100
                             Profit     : $1.10
STRATEGY 2: SELL-SELL
Sell Low   : 1.22000         STRATEGY 4: BUY-SELL
Sell Hi(2) : 1.24500         Buy  Lo(2) : 1.23001
Profit     : -$0.20 (merah)  Buy  Lo(3) : 1.23200
                             Sell Hi(2) : 1.24500
                             Profit     : $0.40
```
- **Profit hijau** = ≥ 0, **merah** = < 0.
- `N/A` = leg yang dibutuhkan strategi belum ada (cek minimum order di §1.9).

### 3.7 Cara Kerja Saat Berjalan
1. Setiap tick EA memindai order, memasang ATR SL pada leg kerja, lalu mengecek tiap strategi.
2. Begitu satu basket memenuhi target, **basket itu ditutup** dan EA berhenti untuk tick ini.
3. Pada tick berikutnya EA memindai ulang kondisi terbaru — aman walau leg dipakai beberapa strategi.

### 3.8 Logging & Troubleshooting
Cek tab **Experts** (dan **Journal**) di MT4. Contoh log berprefix `[DDR]`:
- `Basket SELL-BUY | closed 3/3 | profit=1.10 target=0.95 ...` → sukses.
- `WARNING: basket ... partially closed (2/3)` → 1 leg gagal; dievaluasi ulang tick berikutnya.
- `ATR SL set BUY ticket=... sl=...` → SL terpasang.
- `Close: trading not allowed` → aktifkan AutoTrading / Allow live trading.

| Gejala | Kemungkinan sebab | Solusi |
|--------|-------------------|--------|
| Tidak ada yang ditutup | Profit belum capai target, atau order kurang | Cek dashboard & minimum order (§1.9) |
| S3/S4 selalu `N/A` | Sell/Buy belum cukup untuk `Hi(3)`/`Lo(3)` | Butuh ≥3 order di sisi terkait |
| EA tidak trading | AutoTrading / live trading off | Nyalakan AutoTrading & centang Allow live trading |
| SL tidak terpasang | Profit belum cukup jauh (StopLevel) / ATR=0 | Tunggu profit cukup; cek data bar untuk ATR |
| Pesan "EA EXPIRED" | Lewat `LIC_EXPIRE_DATE` | Hubungi admin untuk update |

### 3.9 Menghentikan / Uninstall
- **Sementara**: matikan **AutoTrading**, atau hapus EA dari chart (label `DDR_` otomatis terhapus saat `OnDeinit`).
- **Permanen**: hapus `DDR_Custom_Assistant.mq4`/`.ex4` dari `MQL4/Experts/`.

> ⚠️ **Uji dulu di akun demo / Strategy Tester** sebelum dipakai di akun real.

---

## 4. Appendix: Changelog & Disclaimer

### Changelog

**v3.0 → v4.0 (strategy rewire)**
- **S3 SELL-BUY** kini `Lo(2) + Hi(2) + Hi(3)` (sebelumnya `buyHigh + Hi(2) + Hi(1)`).
- **S4 BUY-SELL** kini `Lo(2) + Lo(3) + Hi(2)` (sebelumnya `Lo(2) + Lo(1) + sellLow`).
- `Lo(1)` & `Hi(1)` menjadi **anchor display-only** (tidak ditutup otomatis, tanpa ATR SL).
- **Scanner** digeneralisasi ke **top-3 sorted list** (insertion sort) + accessor `BuyLo()/SellHi()`.
- **ATR SL** diperluas ke leg `Lo(3)` & `Hi(3)`.
- Target default **semua strategi = `0.5 $/lot`** (S1/S2 sebelumnya 1.5).
- Dashboard menambah bagian **ANCHORS (hold)** dan label leg baru.

**v2.0 → v3.0 (correctness & resilience)**
- 1 close/tick + re-scan (hindari snapshot basi pada leg bersama).
- Close terverifikasi + retry; partial close di-log.
- SL di-`NormalizeDouble`; ATR & buffer spread jadi opsional; validasi parameter di `OnInit`.

### Disclaimer
Perangkat lunak ini disediakan "apa adanya", tanpa jaminan. Trading mengandung risiko
kehilangan modal. Selalu uji di akun demo terlebih dahulu. Penggunaan pada akun real adalah
tanggung jawab pengguna sepenuhnya.

---
*Copyright © 2024 — Kontak: https://wa.me/+628811230359*
