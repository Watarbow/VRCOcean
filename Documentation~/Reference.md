# VRCOcean リファレンスマニュアル

導入手順は [README](../README.md) を参照。このマニュアルは、各コンポーネント・パラメータ・シェーダープロパティの意味と、仕組み・制約をまとめたもの。

> このフォルダ（`Documentation~`）は名前が `~` で終わるため Unity にはインポートされない。

## 目次

1. [構成](#1-構成)
2. [仕組み](#2-仕組み)
3. [OceanFFT](#3-oceanfft)
4. [ShipSpeed](#4-shipspeed)
5. [マテリアル（Ocean.mat / Spray.mat）](#5-マテリアル)
6. [エディター拡張](#6-エディター拡張)
7. [制約と注意点](#7-制約と注意点)
8. [トラブルシューティング](#8-トラブルシューティング)
9. [テスト](#9-テスト)

---

## 1. 構成

```
VRCOcean/
├── Ocean.prefab              海本体（これをシーンに置く）
├── Scripts/
│   ├── OceanFFT.cs           波の計算・泡・引き波・航空機の風（T#）
│   ├── OceanFFT_*.shader/mat T# が [Kernel] から生成した GPU カーネル（手で編集しない）
│   ├── ShipSpeed.cs          船速スライダー（同期あり）
│   └── *.Tests.cs            [TsukimiTest] のテスト
├── Shaders/
│   ├── Ocean.shader/.mat     海面の描画
│   ├── FoamSim.shader/.mat   泡の持続シミュレーションと、しぶきの粒子更新
│   ├── Spray.shader/.mat     しぶきの描画
│   └── Ships.cginc           船（主艦＋随伴艦）の共通定義
├── Meshes/
│   ├── clipmap_high.obj      海面メッシュ（クリップマップ）
│   └── SprayQuads.asset      しぶき用の板ポリ（64×64 粒子）
├── Editor/
│   ├── AssignAirVehicles.cs  メニュー: 航空機の一括設定
│   └── RestoreMaterialsAfterPlay.cs  再生終了時にマテリアルを元に戻す
└── Documentation~/           このマニュアル
```

### Ocean プレハブ

| オブジェクト | 内容 |
|---|---|
| `Ocean` | `clipmap_high` メッシュ（`Ocean.mat`）と、`OceanFFT` が 4 つ（カスケード 0〜3） |
| `Ocean/Spray` | しぶきのメッシュ（`Spray.mat`） |

プレハブのカスケード設定：

| cascadeIndex | tileLength (m) | bandMin〜bandMax (rad/m) | 担当する波長 | normalScale | whitecap |
|---|---|---|---|---|---|
| 0 | 2003 | 0 〜 0.0871 | 約 72 m 以上（うねり） | 0.22 | 0.65 |
| 1 | 433 | 0.0871 〜 0.3887 | 約 16〜72 m | 1 | 0.5 |
| 2 | 97 | 0.3887 〜 1.618 | 約 3.9〜16 m | 1 | 0.5 |
| 3 | 23.3 | 1.618 〜 100000 | 約 3.9 m 以下 | 1 | 0.5 |

`seed` はカスケードごとに 1234 / 2345 / 3456 / 4567。タイル長を互いに割り切れない値にしてあるのは、繰り返し模様を目立たなくするため。

---

## 2. 仕組み

### 波

各 `OceanFFT`（＝1 カスケード）が毎フレーム以下を GPU で行う。

1. `InitSpectrum`（`Regenerate()` のときだけ）：TMA スペクトル（浅水補正付き JONSWAP）× Hasselmann 方向分布から初期振幅 h0(k) を作る
2. `Modulate`：分散関係 ω(k) で時間発展させ、変位・高さ・傾き・ヤコビアン用の 8 つの実数場を 2 つの複素バッファに詰める
3. `FftX` ×8、`FftY` ×8：256×256 の逆 FFT（Stockham, radix-2）。2 つのバッファを横に並べて 1 回のパスで変換する
4. `UnpackDisp` / `UnpackNormal`：変位マップ（xyz＋ヤコビアン）と、法線・泡マップを書き出す

結果は `_DispTex{N}` / `_NormTex{N}`（リピート・ミップマップ付き）として `Ocean.mat` に渡る。周波数は 400 秒周期に量子化しており、時計を巻き戻しても波が飛ばない。

### 海面メッシュ

カスケード 0 がメッシュをローカルプレイヤーの頭の位置に追従させる（`snapSize` の格子単位で移動するので頂点が泳がない）。高度が `altitudePerScale` を超えるたびにメッシュを 2 倍に拡大（最大 `maxMeshScale` 倍）し、外周は `skirtDistance` まで引き伸ばす。

### 泡

カスケード 0 が `FoamSim.shader` で、プレイヤー周りの世界座標テクスチャを 2 枚（近距離・遠距離）毎フレーム更新する。全カスケードのヤコビアンの和が `whitecap` を下回った場所（波が折り返す場所）に泡が生まれ、表層の流れで漂い、時間で減衰する。テクスチャのチャンネルは：

| ch | 内容 | 寿命パラメータ |
|---|---|---|
| R | 泡 | `foamLifetime` |
| G | 新しい泡（厚く明るく見える） | `foamFreshTime` |
| B | 水中の気泡（海色が明るくなる） | `bubbleLifetime` |
| A | スリック（泡が消えた後の界面活性膜。ラングミュア循環で風向きの筋になる） | `slickLifetime` |

遠距離シミュレーションの外側は、カスケードごとのタイル泡と、シェーダー内のまばらな白波（`_WhitecapDensity`）で補う。

### 船は動かない

主艦は**シーン内で静止したまま**で、代わりに海（波・泡・航跡）が船速で後ろへ流れる。こうすると甲板上のプレイヤーや着艦した航空機の座標を動かさずに済み、同期や物理が単純になる。

- 波のタイルは流れた距離ぶんずらす（double で積算し、タイル長で折り返すので何時間でも精度が落ちない）
- `airVehicles` の SaccAirVehicle には `Wind = 船尾方向 × 船速 ＋ 海上風 × seaWindOnAircraft` を設定する。SaccFlight は対気速度を「速度 − Wind」で計算するので、静止した空母が航行中と同じように振る舞う（甲板上の向かい風、着艦時の相対速度）
- 随伴艦は主艦と同じ針路・速度で航行している扱い。違うのは位置と船体寸法だけ

### 同期

- 波・泡は**各プレイヤーのローカル時計**で計算しており、同期しない（サーバー時刻はフレームごとに揺れ、波がカクついて見えるため）。見た目の波は人によって違う
- 船速（`ShipSpeed`）は同期する。目標速度への加速の開始時刻・距離・速度だけを同期し、各クライアントはサーバー時刻から現在の速度を計算する

---

## 3. OceanFFT

`Scripts/OceanFFT.cs`。1 コンポーネント＝1 カスケード。すべて `Ocean` オブジェクトに付ける。**「カスケード 0 のみ」と書いた項目は、`cascadeIndex` が 0 のものだけが使う。**

### Spectrum（波の形）

変更後は `Regenerate()` を呼ぶ必要がある（再生中にインスペクターで変えても反映されない）。風・吹送距離などはカスケード間で揃えること。

| 項目 | 既定値 | 単位 | 内容 |
|---|---|---|---|
| `tileLength` | 88 | m | 1 タイルの一辺。このカスケードが表せる最長の波長 |
| `windSpeed` | 10 | m/s | 海上 10 m の風速。大きいほど波が高く長くなる |
| `windDirection` | 0 | 度 | 風の吹いてくる向き。0 で +Z 側から吹き、波は −Z へ進む。角度は +Z から +X へ回る向き |
| `fetchKm` | 150 | km | 吹送距離（風が海上を吹き続けた距離）。短いと波が未発達になる |
| `depth` | 20 | m | 水深。浅いと長い波が減衰する（TMA 補正）。分散関係にも効く |
| `swell` | 0.8 | 0〜1 | うねりの度合い。大きいほど波の向きが揃う |
| `spread` | 0.2 | 0〜1 | 方向分布を全方向一様に寄せる割合。0 で風向きに集中、1 で全方向 |
| `detail` | 1 | 0〜1 | 短い波の残し具合。小さいほど細かい波を抑える |
| `seed` | 1234 | — | 乱数の種。カスケードごとに変える |
| `heightScale` | 1 | 倍 | 波高の倍率。1 で物理的な JONSWAP の波高（GodotOceanWaves の約 1/2.83） |

### Foam（泡）

| 項目 | 既定値 | 単位 | 内容 |
|---|---|---|---|
| `whitecap` | 0.5 | — | ヤコビアンがこの値を下回ると泡が出る。大きいほど泡が増える。カスケード 0 の値が泡シミュレーションの閾値になる（0.65 で風速 10 m/s のとき被覆率約 1.4%） |
| `foamAmount` | 8 | — | 泡の生成量。大きいほどタイル泡の減衰も遅くなる |
| `foamSimMaterial` | FoamSim.mat | — | 泡シミュレーションのマテリアル。空だと泡シミュレーション・しぶきとも無効 |
| `foamLifetime` | 4 | s | 泡の減衰時間（e 倍で減る時間） |
| `foamSimSize` | 512 | m | 近距離シミュレーションの範囲（一辺） |
| `foamSimResolution` | 1024 | px | 近距離シミュレーションの解像度 |
| `foamFarSize` | 4096 | m | 遠距離シミュレーションの範囲 |
| `foamFarResolution` | 512 | px | 遠距離シミュレーションの解像度 |
| `foamFreshTime` | 0.7 | s | 泡が「新しい」（厚く白い）と見える時間 |
| `bubbleLifetime` | 6 | s | 水中の気泡の寿命 |
| `slickLifetime` | 60 | s | スリック（筋）の寿命 |
| `foamDrift` | 0.03 | 風速比 | 泡が風下へ流れる速さ（吹送流＋ストークスドリフト） |
| `foamCurrent` | (0, 0) | m/s | 海流（ワールド X, Z） |
| `langmuirSpeed` | 0.1 | m/s | ラングミュア循環の収束速度（スリックを筋に集める強さ） |
| `langmuirSpacing` | 30 | m | 筋の間隔 |

`foamSimSize` 〜 `langmuirSpacing` はカスケード 0 のみ。解像度は起動時にしか反映されない。

### Ship wake（カスケード 0 のみ）

| 項目 | 既定値 | 単位 | 内容 |
|---|---|---|---|
| `ship` | なし | — | 主艦の Transform。空なら引き波・海の流れ・航空機の風はすべて無効 |
| `shipSpeed` | 15 | m/s | 船速（`speedControl` が空のとき） |
| `speedControl` | なし | — | `ShipSpeed`。設定するとそちらの同期された速度を使う |
| `shipBow` | (0.77, 16, 258.8) | m | 艦首の水線位置。船のローカル軸の向きで、ピボットからの距離（スケールは無視） |
| `shipLength` | 479 | m | 水線長 |
| `shipBeam` | 56 | m | 水線幅 |
| `shipDraft` | 15 | m | 喫水。これより短い波長は船体からあまり出ない |
| `kelvinHeight` | 1 | m | ケルビン波の振幅（船の 1 艇身後方での値） |
| `bowHumpHeight` | 1.5 | m | 艦首の水の盛り上がり |
| `wakeFoam` | 1 | /s | 船尾で巻き上がる泡の量 |
| `escorts` | 空 | — | 随伴艦の Transform（最大 3） |
| `escortBow` | 空 | m | 各随伴艦の艦首水線位置（`shipBow` と同じ扱い） |
| `escortHull` | 空 | m | 各随伴艦の (水線長, 幅, 喫水) |

- 船の向きは `ship.forward` の水平成分。主艦が回頭すると海の流れる向きも変わる
- 随伴艦は `escorts`・`escortBow`・`escortHull` の 3 配列の同じ番号を 1 隻として扱う。どれかが欠けている番号は無視する。水線長 0 で無効
- 随伴艦のケルビン波と艦首の盛り上がりは、主艦の値を幅の比で縮めたもの

### Spray（カスケード 0 のみ）

| 項目 | 既定値 | 単位 | 内容 |
|---|---|---|---|
| `sprayMaterial` | Spray.mat | — | しぶき描画のマテリアル。空ならしぶきなし |
| `sprayAmount` | 1 | 倍 | しぶきの量 |
| `slamThreshold` | 1 | m/s | 艦首の海面がこれより速く上昇するとスラミング（叩きつけ）のしぶきが出る |

しぶきは 64×64 = 4096 粒子の GPU パーティクル。主艦と随伴艦の艦首から出る。

### SaccFlight（カスケード 0 のみ）

| 項目 | 既定値 | 単位 | 内容 |
|---|---|---|---|
| `airVehicles` | 空 | — | SaccAirVehicle の UdonBehaviour の配列 |
| `seaWindOnAircraft` | 1 | 倍 | 海上風（`windSpeed`, `windDirection`）を航空機に与える割合。0 で船の動きによる風だけ |

風は値が変わったときだけ `SetProgramVariable("Wind", …)` で書き込む。

### Cascade

| 項目 | 既定値 | 単位 | 内容 |
|---|---|---|---|
| `cascadeIndex` | 0 | 0〜3 | カスケード番号。重複させないこと |
| `bandMin` / `bandMax` | 0 / 100000 | rad/m | このカスケードが担当する波数の範囲。隣と隙間・重なりがないように揃える（波数 k = 2π / 波長） |
| `displacementScale` | 1 | 倍 | 変位（高さ・横ずれ）の倍率 |
| `normalScale` | 1 | 倍 | 法線（傾き）の倍率 |

### Rendering

| 項目 | 既定値 | 単位 | 内容 |
|---|---|---|---|
| `oceanMaterial` | Ocean.mat | — | 海面のマテリアル。全カスケードで同じものを指定する |
| `snapSize` | 4 | m | メッシュが移動する格子幅。`clipmap_high` の最も粗いリングの頂点間隔に合わせる |
| `altitudePerScale` | 60 | m | 海面からの高さがこの値 × 現在の倍率を超えるたびにメッシュを 2 倍にする |
| `maxMeshScale` | 64 | 倍 | メッシュ拡大の上限 |
| `skirtDistance` | 45000 | m | 外周を引き伸ばす距離。カメラの Far Clip より小さくする |

`snapSize` 以下はカスケード 0 のみ使用。

### メソッド

| メソッド | 内容 |
|---|---|
| `Regenerate()` | Spectrum の値から初期スペクトルを作り直す。起動時に自動で呼ばれる。他の Udon から `SendCustomEvent("Regenerate")` で呼べる |

---

## 4. ShipSpeed

`Scripts/ShipSpeed.cs`。船速を全員で共有する（Manual 同期）。スライダーで目標速度を決めると、船は `acceleration` で一定に加速・減速して近づく。

| 項目 | 既定値 | 単位 | 内容 |
|---|---|---|---|
| `slider` | なし | — | UI の Slider（`UnityEngine.UI`）。値が目標速度（m/s） |
| `label` | なし | — | UI の Text。「Ship speed 15.0 m/s (29 kn) -> 20.0」のように表示 |
| `acceleration` | 0.3 | m/s² | 加減速の速さ（0 → 15 m/s に 50 秒） |
| `initialSpeed` | 15 | m/s | 開始時の速度 |

### 設定手順

1. Canvas（World Space）に Slider と Text を置く
2. 任意のオブジェクトに `ShipSpeed` を付け、`slider` と `label` を設定する
3. Slider の **On Value Changed** に、`ShipSpeed` の UdonBehaviour の `SendCustomEvent(string)` を追加し、引数を `OnSliderChanged` にする
4. カスケード 0 の `OceanFFT.speedControl` にこの `ShipSpeed` を設定する

### メソッド

| メソッド | 内容 |
|---|---|
| `float SpeedAt(double t)` | サーバー時刻 `t` での速度（m/s） |
| `double DistanceAt(double t)` | サーバー時刻 `t` までに海が流れた距離（m） |
| `void SetTarget(float speed, double now)` | 目標速度を設定する（オーナーを取得して同期） |
| `void OnSliderChanged()` | スライダーから呼ぶイベント |

---

## 5. マテリアル

### Ocean.mat（`VRCOcean/Ocean`）

ライティングは GodotOceanWaves の water.gdshader（Atlas GDC 2019 の BSDF、GGX）に基づく。反射はリフレクションプローブ / スカイボックスを Schlick フレネル（F0 = 0.02）で合成する。

| プロパティ | 既定値 | 内容 |
|---|---|---|
| `_Chlorophyll` | 0.2 | クロロフィル濃度（mg/m³）。海の色は純水＋クロロフィルの光学特性から計算する。0.05 で深い青、1 で緑がかった沿岸 |
| `_SSSStrength` | 1 | 波頭を透過する光（サブサーフェス散乱）の強さ |
| `_FoamColor` | (0.8, 0.8, 0.8) | 泡の色 |
| `_Roughness` | 0.4 | 面の粗さ |
| `_NormalStrength` | 1 | 法線の強さ |
| `_DispScale` | 1 | 変位全体の倍率 |
| **Sun Glints** | | |
| `_GlintIntensity` | 4 | 太陽のきらめきの強さ（1 でエネルギー保存） |
| `_GlintCell` | 0.15 | きらめき 1 つの大きさ（m） |
| `_GlintSlope` | 0.08 | きらめきを生む微小面の傾き |
| `_GlintCone` | 0.08 | 太陽の見かけの広がり（rad） |
| `_GlintSpeed` | 3 | きらめきの明滅の速さ |
| `_SunSheen` | 0.35 | 滑らかな太陽ハイライトの割合 |
| `_SpecMax` | 2 | ハイライトの上限（HDR。ブルームの暴れを抑える） |
| **Horizon** | | |
| `_HorizonTilt` | 1 | 遠方の微小面を視点側へ傾け、地平線付近を暗くする |
| `_HorizonFog` | 1 | フォグ距離を地平線までで打ち切る（0 で無効） |
| `_FogSky` | 1 | フォグ色をスカイボックスの地平線色から取る（0 でシーンのフォグ色） |
| `_HazeHeight` | 1000 | もやのスケールハイト（m）。上空からはフォグが薄くなる（0 で無効） |
| **Foam** | | |
| `_FoamCell` | 1.2 | 泡のレース模様のセル（m） |
| `_FoamStreaks` | 0.3 | スリック上に残る泡（筋）の量 |
| `_WhitecapCell` | 12 | 遠方の白波のセル（m、1 セルに最大 1 つ） |
| `_WhitecapDensity` | 0.01 | 遠方で砕けているセルの割合（0 でなし） |
| `_SlickDamping` | 0.6 | スリックが細かい波を消す強さ |
| `_BubbleScatter` | 0.01 | 水中の気泡による後方散乱（1/m） |

`_Cascade*`、`_DispTex*`、`_NormTex*`、`_FoamSim*`、`_WindDown`、`_Ship*`、`_Wake*`、`_Escort*`、`_MeshScale`、`_SkirtDistance` などは実行時に `OceanFFT` が設定する。手で変えても上書きされる。

### Spray.mat（`VRCOcean/Spray`）

水滴を二重 Henyey-Greenstein 位相関数で照らす（前方散乱が強く、逆光で光る）。

| プロパティ | 既定値 | 内容 |
|---|---|---|
| `_Color` | (0.9, 0.92, 0.93) | 水滴のアルベド |
| `_Opacity` | 0.4 | 不透明度 |
| `_Size` | 2.4 | 粒子 1 つの大きさ（m） |
| `_ForwardG` | 0.8 | 前方ローブの g |
| `_BackG` | −0.3 | 後方ローブの g |
| `_ForwardWeight` | 0.75 | 前方ローブの重み |

### FoamSim.mat（`Hidden/VRCOcean/FoamSim`）

内部用。設定項目はない。

---

## 6. エディター拡張

### Tools > VRCOcean > Assign Air Vehicles

開いているシーン内のすべての SaccAirVehicle（非アクティブも含む）を、カスケード 0 の `OceanFFT.airVehicles` に設定する。結果はコンソールに出る。SaccFlight が入っていないプロジェクトでもコンパイルできる（型名で探すため）。

### 再生終了時のマテリアル復元

`OceanFFT` は実行中にマテリアルアセットへ値を書き込む。エディターではその変更が再生終了後も残り、`.mat` に差分が出てしまうため、再生開始時に VRCOcean フォルダ内の全マテリアルを保存し、終了時に戻す。自動で動くので操作は不要。

---

## 7. 制約と注意点

- **1 シーンに 1 つまで。** マテリアルアセットを直接書き換えるため、2 つ置くと互いに上書きする
- **カスケード 0 は必須。** メッシュの追従・泡・船・航空機はすべてカスケード 0 が担う
- **波は同期しない。** プレイヤーごとに見える波は異なる。波に浮かぶ物を同期する用途には向かない
- **船は 1 隊のみ。** 主艦＋随伴艦 3 隻が同じ針路・速度で進む前提。個別に動く船は表現できない
- **主艦は静止させる。** `ship` を実際に動かすと、海の流れと二重になる
- **GPU 負荷。** 毎フレーム、カスケードごとに 256² の FFT（約 20 パス）、加えて泡シミュレーション（1024² と 512²）を回す。重い場合は `foamSimResolution` / `foamFarResolution` を下げる
- **`OceanFFT_*.shader` / `.mat` は自動生成。** T# が `[Kernel]` メソッドから生成するので、直接編集しない

---

## 8. トラブルシューティング

| 症状 | 確認すること |
|---|---|
| 海が出ない / 真っ黒 | TsukimiSharp が入っているか。コンソールにコンパイルエラーがないか。`oceanMaterial` が設定されているか |
| 再生後に `.mat` が変更扱いになる | `Editor/RestoreMaterialsAfterPlay.cs` がコンパイルされているか |
| 泡が出ない | カスケード 0 の `foamSimMaterial` と `oceanMaterial` が設定されているか。`whitecap` を上げる |
| 引き波が出ない | カスケード 0 の `ship` が設定されているか。船速が 0 でないか |
| 引き波の位置がずれる | `shipBow` が艦首の水線（船のローカル軸、m）を指しているか。船のスケールは無視される |
| しぶきが出ない | `sprayMaterial` と `foamSimMaterial` の両方が設定されているか |
| 上空から海が途切れる | カメラの Far Clip が `skirtDistance` より大きいか |
| 航空機の速度計がおかしい | `airVehicles` に入れた機体が SaccAirVehicle か。他のスクリプトが `Wind` を書き換えていないか |
| 遠くで波の模様が繰り返して見える | カスケード同士の `tileLength` を割り切れない値にする。`seed` を変える |

---

## 9. テスト

`*.Tests.cs` の `[TsukimiTest]` は TsukimiSharp のテストとして実行できる。

| テスト | 確認内容 |
|---|---|
| `StockhamMatchesInverseDft` | FFT カーネルの添字計算が直接計算した逆 DFT と一致する |
| `PackedFftStaysInHalf` | 2 つ並べたバッファの FFT が自分の半分しか読まない |
| `SpectrumConstants` | JONSWAP の定数 |
| `MeshScaleDoublesWithAltitude` | 高度によるメッシュ倍率 |
| `FlowOffsetStaysExact` | 長時間流れてもタイルのずれが正確 |
| `RampEasesToTheTarget` | 船速が目標へ一定加速度で近づく |
| `ChangingTargetMidRampKeepsSpeedAndDistance` | 加速中に目標を変えても速度・距離が連続する |
| `EveryoneComputesTheSameFlow` | 全クライアントが同じ流れた距離を計算する |
