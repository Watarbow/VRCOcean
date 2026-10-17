# VRCOcean

VRChat ワールド用の FFT 海洋シミュレーション。[TsukimiSharp](https://tsukimi-reference.pages.dev/reference/)（T#）で書かれ、波の計算をすべて GPU で行う。

*An FFT ocean for VRChat worlds, written in TsukimiSharp. MIT licensed.*

## 特長

- **FFT 海洋**：TMA スペクトル＋Hasselmann 方向分布から 256×256 の逆 FFT を毎フレーム GPU で計算。4 カスケード（波長帯）で数 km 規模のうねりから 10 cm 程度のさざ波まで重ねる
- **地平線まで続く海面**：プレイヤーに追従するクリップマップ。高度に応じて拡大し、航空機から見下ろしても切れない
- **泡**：白波の発生・漂流・減衰を世界座標で持続シミュレーション（近距離 512 m＋遠距離 4 km）。泡の跡に残るスリック（筋）、気泡による海色の変化も表現
- **水中**：潜ると、見上げた海面にスネルの窓と全反射、周りは水の吸収・散乱から計算した青い霞（赤から先に消える）
- **船の引き波**：ケルビン波、艦首の盛り上がり、航跡の泡、艦首のしぶき（GPU パーティクル）。主艦＋随伴艦 3 隻まで
- **SaccFlight 連携**：「船は動かず、海が流れる」方式。艦上のプレイヤーと着艦する航空機の座標を固定したまま航行を表現し、航空機には船速ぶんの相対風を与える
- **速度の同期**：甲板のスライダーで船速を変えると全員に同期（後から入ったプレイヤーも同じ状態になる）

## 必要なもの

- Unity 2022.3（2022.3.22f1 で開発）
- VRChat SDK - Worlds 3.10.4 以上（UdonSharp 同梱）
- TsukimiSharp（`com.tsukimicode.udon-tools`）0.9.0 以上

SaccFlightAndVehicles は任意。無くてもコンパイル・動作する。

## 導入

1. VCC / ALCOM で上記パッケージをプロジェクトに追加する。
2. プロジェクトの `Assets` フォルダで clone する。

   ```
   cd <プロジェクト>/Assets
   git clone https://github.com/Watarbow/VRCOcean
   ```

   `Assets/VRCOcean/` ができる。フォルダ名は変えても動く。git を使わない場合は ZIP をダウンロードして `Assets` 以下に展開してもよい。
3. Unity に戻り、スクリプトのコンパイルが終わるのを待つ。
4. `Assets/VRCOcean/Ocean.prefab` をシーンに置く。

これで海が出る。1 シーンに置けるのは 1 つまで（マテリアルを共有しているため）。

## 船・航空機との連携（任意）

`Ocean` に付いている `OceanFFT` のうち、`cascadeIndex` が 0 のものに設定する。

| 項目 | 内容 |
|------|------|
| `ship` | 船の Transform。設定すると引き波が出る |
| `shipBow` / `shipLength` / `shipBeam` / `shipDraft` | 艦首の水線位置（船のローカル軸、m）と、水線長・幅・喫水（m） |
| `escorts` / `escortBow` / `escortHull` | 随伴艦（最大 3 隻）の Transform、艦首の水線位置、水線長・幅・喫水。針路と速度は `ship` と共通 |
| `speedControl` | `ShipSpeed`（速度スライダー）。未設定なら `shipSpeed` の固定値 |
| `airVehicles` | SaccAirVehicle の UdonBehaviour。メニュー **Tools > VRCOcean > Assign Air Vehicles** でシーン内のものを一括設定できる |
| `sprayMaterial` | 艦首のしぶき（`Shaders/Spray.mat`、プレハブ設定済み）。空にすると出ない |

どれも空のままで動く。全項目の説明は [リファレンスマニュアル](Documentation~/Reference.md) を参照。

## 更新

```
cd <プロジェクト>/Assets/VRCOcean
git pull
```

## ドキュメント

- [リファレンスマニュアル](Documentation~/Reference.md) — 全パラメータ、シェーダーのプロパティ、仕組み、制約、トラブルシューティング

## ライセンス

[MIT License](LICENSE)。

波のスペクトル・FFT・ライティングは [GodotOceanWaves](https://github.com/2Retr0/GodotOceanWaves)（MIT, © 2024 Ethan Truong）の移植。海面メッシュ `Meshes/clipmap_high.obj` も同プロジェクトのもの。原ライセンスは [`Meshes/GodotOceanWaves-LICENSE.txt`](Meshes/GodotOceanWaves-LICENSE.txt) を参照。

FFT は GodotOceanWaves が参考にした [OTFFT](http://wwwa.pikara.ne.jp/okojisan/otfft-en/stockham3.html)（MIT, Takuya Okahisa）の Stockham 法に基づく。
