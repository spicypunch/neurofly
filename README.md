<div align="center">

<img src="docs/assets/neurofly-banner.svg" alt="NeuroFly — A little fly. A real connectome." width="100%" />

### 바탕화면 위의 작은 초파리, 실제 연결 데이터로 움직이는 신경망

먹이를 놓고, 반응을 관찰하고, 개체마다 쌓이는 기억을 살펴보세요.<br />
**FlyWire · Male CNS · Metal · macOS**

<img alt="macOS 15 이상" src="https://img.shields.io/badge/macOS-15%2B-172D25?style=flat-square&amp;logo=apple&amp;logoColor=white" />
<img alt="Swift tools 6.0" src="https://img.shields.io/badge/Swift_tools-6.0-EA805C?style=flat-square&amp;logo=swift&amp;logoColor=white" />
<img alt="Metal GPU compute" src="https://img.shields.io/badge/Compute-Metal-284D3F?style=flat-square" />
<img alt="독립 개체 1–4마리" src="https://img.shields.io/badge/Pets-1–4-416653?style=flat-square" />

[앱 다운로드](#앱-다운로드) · [소스 빌드](#빠른-시작) · [사용하기](#사용하기) · [어떻게 움직이나요](#어떻게-움직이나요) · [검증](#검증) · [데이터와 이용 조건](#데이터와-이용-조건)

</div>

---

## 작은 펫, 관찰할 수 있는 뇌 반응

**NeuroFly**는 실제 초파리의 신경 연결 지도인 *커넥톰*을 이용하는 독립 macOS 데스크톱 펫입니다.
큰 창 없이 바탕화면에서 실행되고, 평소에는 클릭을 아래 앱으로 통과시킵니다.
먹이와 자극을 배치할 때만 클릭을 받으며, 상태 창과 실험실은 필요할 때 열 수 있습니다.

| 기능 | 해볼 수 있는 일 |
| :--- | :--- |
| 🍌 **먹이 탐색** | 바나나·베리를 놓고 냄새 감지 → 신경 반응 → 이동 → 섭식 과정을 관찰합니다. |
| 🌘 **자극과 반응** | 그림자·접촉 자극을 주거나 감각 입력을 꺼서 신경 출력의 차이를 비교합니다. |
| 🍽️ **배고픔과 포만** | 먹은 양만큼 허기가 줄고, 시간이 지나 다시 먹이를 찾는 주기를 관찰합니다. |
| 🧠 **먹이 기억** | 실제 섭취·최근 위협과 냄새 단서의 연합, 시간에 따른 망각을 관찰합니다. |
| 🪰 **최대 4개체** | 독립된 신경망·몸체·기억을 가진 펫들이 같은 먹이와 환경을 공유합니다. |
| 🔬 **두 연결 지도** | FlyWire v783과 Male CNS v1.0을 전환하고 선택 개체의 상태를 확인합니다. |

<table>
<tr>
<td width="42%" align="center" valign="top">
<img src="docs/assets/neural-status.png" alt="초기 버전의 NeuroFly 상태 창: 감각 입력, 후각 중계, 운동 뉴런 발화율" width="280" />
<br /><sub>초기 버전의 상태 창 예시</sub>
</td>
<td valign="top">

### 움직임 뒤의 신호를 직접 보기

상태 창에서는 다음을 함께 볼 수 있습니다.

- **감각 입력** — 몸 기준 좌우 냄새, 단맛, 그림자, 접촉
- **후각 중계** — 연결망을 통과한 DM1_lPN 뉴런의 활동
- **운동 출력** — 선회·전진·회피·섭식 관련 뉴런의 발화율
- **몸 상태** — 실제 속도·선회, 허기·누적 섭취량
- **먹이 기억** — 바나나·베리 연합값과 입력에 적용되는 gain
- **개체와 모델** — 관찰 대상, 학습 설정, 현재 연결 지도

왼쪽 사진은 초기 버전입니다. 현재 상태 창에는 개체·모델 선택과 허기·기억 항목이 추가되어 있습니다.

</td>
</tr>
</table>

> **어떤 시뮬레이션인가요?**
> 실제 연결 그래프에 단순화한 신경 계산과 2D 몸체를 결합한 실험입니다.
> 허기·연합 기억·감각 입력 변환·운동 해석에는 앱에서 설계한 규칙이 들어갑니다.
> 생물의 뇌 전체나 실제 비행을 완전히 재현한 모델은 아니며, Codex 내장 펫과 별도로 실행합니다.

## 앱 다운로드

**[NeuroFly 0.2.0 미리보기 다운로드 · Apple Silicon](https://github.com/spicypunch/neurofly/releases/download/v0.2.0/NeuroFly-0.2.0-macos-arm64.zip)**

macOS 15 이상에서 ZIP을 풀고 `NeuroFly.app`을 응용 프로그램 폴더로 옮겨 실행하세요.
두 뇌 데이터가 포함되어 있어 **Xcode·Python·추가 다운로드 없이** 실행할 수 있습니다.
현재 실행 파일은 Apple Silicon 전용입니다.

이 미리보기는 **ad hoc 서명이며 Apple 공증을 받지 않았습니다.** 첫 실행 시 macOS가 차단하면
앱을 열려고 시도한 뒤 `시스템 설정 → 개인정보 보호 및 보안 → 그래도 열기`에서 앱별로 허용할 수 있습니다.
관리되는 Mac에서는 이 옵션이 제한될 수 있습니다.

[설치·서명 안내](docs/install.md) · [릴리스와 SHA-256 확인 파일](https://github.com/spicypunch/neurofly/releases/tag/v0.2.0)

## 빠른 시작

### 준비물

| 항목 | 요구 사항 |
| :--- | :--- |
| Mac | macOS 15 이상 · Metal 지원 GPU · Apple Silicon에서 검증 |
| 빌드 도구 | Swift 6 도구가 포함된 Xcode 또는 Command Line Tools |
| 데이터 준비 | Python 3.11 권장(검증 환경) · 최초 다운로드를 위한 인터넷 연결 |

```sh
git clone https://github.com/spicypunch/neurofly.git
cd neurofly

# FlyWire 고정 데이터 다운로드 · 약 95 MB
python3 scripts/fetch-data.py

# Male CNS 공식 원본 다운로드·검증·변환 · 원본 약 1.1 GB
python3.11 -m venv .venv-malecns
.venv-malecns/bin/python -m pip install -r scripts/requirements-malecns.txt
.venv-malecns/bin/python scripts/fetch-malecns.py --import

# 두 모델을 포함한 macOS 앱 빌드·실행
./scripts/build-app.sh
open dist/NeuroFly.app
```

- **데이터 바이너리와 빌드된 앱은 Git에 포함되지 않습니다.** 위 명령으로 내려받거나 생성합니다.
- 다운로드 스크립트는 고정된 크기와 SHA-256을 확인하고, 이미 검증된 파일은 재사용합니다.
- 앱 빌드는 **두 모델의 데이터가 모두 준비된 상태**를 요구합니다.
- 완성된 앱에는 실행에 필요한 데이터가 포함됩니다. **앱 실행 중에는 Python과 인터넷이 필요 없습니다.**
- 로컬 빌드는 ad hoc 서명입니다. Apple 공증 배포본은 아니며, 로그인 시 자동 실행도 등록하지 않습니다.

Male CNS 원본 파일·변환 규칙·재현 절차는 [데이터 준비 안내](scripts/README-malecns.md)에 있습니다.

배포 ZIP을 직접 만들려면 데이터를 준비한 뒤 `./scripts/package-release.sh`를 실행합니다.
앱을 빌드하고 설치 안내·이용 조건·SHA-256 확인 파일을 `dist/`에 생성합니다.

## 사용하기

**메뉴 막대의 🪰에서 시작하세요.**

| 하고 싶은 일 | 방법 |
| :--- | :--- |
| 먹이 놓기 | 바나나 또는 베리를 선택하고 화면의 위치를 클릭합니다. 최대 8개까지 놓을 수 있습니다. |
| 그림자·접촉 자극 | `그림자 드리우기` 또는 `건드리기`를 선택한 뒤 클릭합니다. 접촉은 선택 개체에 적용됩니다. |
| 상태 보기 | 상태 창에서 관찰할 개체와 뇌 모델을 고릅니다. |
| 개체 늘리기·줄이기 | 개체를 추가하거나 선택한 개체를 제거합니다. 1–4마리를 유지합니다. |
| 학습 비교 | 선택 개체의 `먹이 기억 학습`을 끄면 입력 gain이 중립값 1이 됩니다. 저장된 연합값은 유지됩니다. |
| 기억 초기화 | 선택 개체의 기억만 지우거나, `전체 초기화`로 모든 개체의 몸 상태·허기·기억과 환경을 초기화합니다. |
| 먹이 치우기 | 배치된 먹이를 제거합니다. 몸 상태와 기억은 유지됩니다. |
| 잠시 멈추기 | `일시정지`로 신경 계산과 몸체 진행을 함께 멈춥니다. 펫을 숨기기만 하면 계산은 계속됩니다. |
| 실험실 열기 | 별도 실험창에서 관찰합니다. 창을 닫으면 바탕화면 펫으로 돌아갑니다. |

| 단축키 | 동작 |
| :---: | :--- |
| `⌘B` | 상태 창 열기 |
| `⌘L` | 실험실 열기 |
| `⌘D` | 데스크톱 모드 |
| `⌘P` | 일시정지 / 다시 시작 |
| `⌘Q` | NeuroFly 종료 |
| `Esc` | 먹이·자극 배치 취소 |

### 저장되는 것

모델 선택, 개체 ID·seed, 선택 개체, 학습 설정과 기억을
`~/Library/Application Support/NeuroFly/colony-v1.json`에 저장합니다.
재실행하면 기억은 복원되고, 몸체는 허기 65%와 빈 환경에서 시작합니다.
먹이 위치·몸 상태·뉴런 막전압·시뮬레이션 시계는 저장하지 않습니다.

모델을 전환할 때는 기존 환경·몸체·기억을 유지하고 새 신경망을 준비합니다.
준비에 실패하면 기존 개체군을 유지합니다. 저장된 모델 선택이 없는 첫 실행은 Male CNS를 우선 사용하며,
CLI 진단의 기본 모델은 FlyWire입니다.

## 어떻게 움직이나요?

```text
화면의 먹이·자극
    ↓
가상 감각 수용기 → 허기에 따른 냄새·단맛 조절 + 기억에 따른 냄새 조절
    ↓
선택한 커넥톰 + Metal 신경 계산
    ↓
뉴런 발화율 → 운동 해석 → 화면 속 몸체 이동
    ↑                         ↓
    └──── 다음 감각 입력 · 실제 섭취로 이어지는 반복 ────┘
```

Metal GPU에서 1ms 단계의 **leaky integrate-and-fire** 모델을 계산합니다.
운동을 해석하는 `MotorDecoder`는 뉴런 출력과 그 이력을 사용하며, **먹이 좌표나 목적지를 받지 않습니다.**
먹이는 냄새와 접촉 미각을 통해 신경망에 영향을 주고, 화면 경계는 별도의 물리 규칙으로 처리합니다.

### 허기와 기억

- **허기**는 시간에 따라 증가하고 실제 섭취량에 따라 감소합니다. 20% 이하에서 먹이 입력을 줄이고,
  60% 이상으로 회복되면 다시 활성화합니다. 그림자·접촉 입력에는 이 조절을 적용하지 않습니다.
- **연합 기억**은 실제로 먹은 양을 양의 보상으로 사용합니다. 냄새나 단맛만으로 보상이 생기지 않습니다.
  최근 위협은 냄새 단서의 연합값을 낮추고, 기억은 시간에 따라 약해집니다.
- 기억은 **냄새 입력의 gain을 바꾸는 앱 수준 모델**입니다. 커넥톰의 시냅스 가중치를 학습으로 수정하지 않습니다.
- 개체마다 신경 상태·몸체·기억이 분리됩니다. 공유 먹이는 실제로 소비한 양만큼 함께 줄어듭니다.

신경망의 기본 발화, 입력 크기, 데이터셋별 gain, 뉴런 출력의 움직임 변환은 공학적으로 보정한 값입니다.
연결 수·가중치를 읽는 것과 생물학적 신경 동역학을 완전히 재현하는 것은 다릅니다.
세부 보정값과 검증 범위는 [검증 기록](docs/verification.md)에 정리했습니다.

## 검증

**Apple M1 Pro에서 실행 · 최종 확인 2026-10-06 KST**

| 항목 | FlyWire v783 | Male CNS v1.0 |
| :--- | :--- | :--- |
| 먹이 탐색 | 18/18 배치에서 접촉·양의 섭취량 | 18/18 배치에서 접촉·양의 섭취량 |
| 감각 차단 대조군 | 3조건 모두 무자극 신경·이동 결과와 일치 | 3조건 모두 무자극 신경·이동 결과와 일치 |
| 허기 주기 | 섭식 → 포만 → 회복 → 두 번째 식사 | 섭식 → 포만 → 회복 → 두 번째 식사 |
| 기억 | 섭취 보상·반응 변화·저장·위협 반전·망각 확인 | 섭취 보상·반응 변화·저장·위협 반전·망각 확인 |
| 2·4개체 | 독립 신경망·기억·선택 자극 격리, 먹이 총량 보존 | 독립 신경망·기억·선택 자극 격리, 먹이 총량 보존 |
| 2개체 / 4개체 계산 속도¹ | 실시간의 **5.03× / 2.22×** | 실시간의 **2.36× / 1.19×** |

**코어 테스트 67개 통과 · GUI 확인 26개 통과 · 앱 빌드·ad hoc 서명 확인**

¹ 개체군 속도는 화면 렌더링과 시작 준비 시간을 제외한 headless 측정값입니다.
FlyWire 허기·개체군 측정은 2026-10-02, 두 모델의 먹이 탐색·학습과 Male CNS의 나머지 검증은
2026-10-06 결과입니다.

이 결과는 고정 seed와 진단 조건에서 확인했습니다. 임의 배치의 탐색 성공이나 최단 경로를 보장하지 않습니다.
Male CNS 일부 배치는 30초 관찰 종료 직전에 접촉했으며, 4개체 실험에서 한 개체는 먹지 못했습니다.
학습 실험은 신경 반응·경로·선택의 변화를 확인했지만 **더 나은 먹이 선호를 입증하지는 않았습니다.**
Male CNS 접촉 입력의 뚜렷한 운동 효과도 아직 확인하지 못했습니다.

[전체 검증 기록](docs/verification.md) · [수치와 GUI 확인 요약 JSON](docs/verification-summary.json)

<details>
<summary><strong>직접 검증 실행하기</strong></summary>

데이터를 준비한 프로젝트 폴더에서 실행합니다. `model`을 `flywire-v783`으로 바꾸면 같은 절차로 비교할 수 있습니다.

```sh
swift test -c release
mkdir -p artifacts
model=malecns

swift run -c release NeuroFly --probe --model "$model" > "artifacts/probe-$model.json"

swift run -c release NeuroFly --foraging --model "$model" > "artifacts/foraging-$model.json"
python3 scripts/verify-foraging.py "artifacts/foraging-$model.json" --require-full-grid --require-contact

swift run -c release NeuroFly --hunger --model "$model" > "artifacts/hunger-$model.json"
python3 scripts/verify-hunger.py "artifacts/hunger-$model.json"

swift run -c release NeuroFly --learning --model "$model" > "artifacts/learning-$model.json"
python3 scripts/verify-evolution.py "artifacts/learning-$model.json" --learning

swift run -c release NeuroFly --population --model "$model" > "artifacts/population-$model.json"
python3 scripts/verify-evolution.py "artifacts/population-$model.json" --population
```

원본 진단 출력은 로컬 `artifacts/`에 생성되며 Git에서 제외됩니다.
공개 저장소에는 [검증 요약](docs/verification-summary.json)을 포함합니다.
원저자 v630 Brian2 모델의 별도 재현은 [reference 실험 안내](tools/reference/README.md)를 참고하세요.
이 앱의 수정된 Metal 모델과 원저자 모델을 수치적으로 동일하게 취급하지 않습니다.

</details>

## 프로젝트 구조

```text
Sources/NeuroFlyCore/    연결 데이터 · Metal 계산 · 허기 · 기억 · 개체군
Sources/NeuroFly/        AppKit/SpriteKit 펫 · 메뉴 · 상태 창 · 실행 루프
Tests/                  코어 회귀 테스트
scripts/                데이터 다운로드·변환 · 앱 빌드 · 진단 검증
data/                   고정 데이터 명세 · 출처와 이용 조건
docs/                   이미지 · 검증 기록과 수치 요약
tools/reference/        원저자 Brian2 모델의 별도 재현 도구
```

## 데이터와 이용 조건

| 모델 | 뉴런 / annotated body | 방향성 연결 | 집계 synapse | 데이터 이용 조건 |
| :--- | ---: | ---: | ---: | :--- |
| **FlyWire FAFB v783** | 139,255 | 15,091,983 | 54,492,922 | [CC BY-NC 4.0](data/DATA_LICENSE.md) |
| **Male CNS v1.0** | 166,700 | 25,582,938 | 124,177,617 | [CC BY 4.0](data/malecns/DATA_LICENSE.md) |

Male CNS 수치는 고정된 공식 v1.0 export에서 `superclass`가 있는 annotated body와 양 끝점이
그 집합에 포함되는 연결을 가져온 결과입니다. 원본 pin, 경계 밖 행 제외, 부호 가정과 출처는
[Male CNS 데이터 고지](data/malecns/DATA_LICENSE.md)에 기록했습니다.

코드와 데이터의 이용 조건은 별개입니다. 두 모델을 함께 묶는 기본 앱에는 비상업적 조건의 FlyWire 데이터도 포함됩니다.
아래 연구·프로젝트와 각 데이터의 attribution을 확인해 주세요.

- **[SiliconFly](https://github.com/dawsonamf/siliconfly/tree/8839d84cd24888a4251a2e227792b6f26fbee776)** — Metal 계산과 로딩 코드를 참고·수정했습니다. [원 코드의 MIT 고지](ThirdParty/SiliconFly-LICENSE)를 보존했습니다.
- **[FlyWire](https://flywire.ai/)** — FAFB v783 연결 데이터. [데이터 출처·논문·이용 조건](data/DATA_LICENSE.md).
- **[Shiu et al., Nature 2024](https://doi.org/10.1038/s41586-024-07763-9)** — 기준 연구와 [원저자 모델](https://github.com/philshiu/Drosophila_brain_model).
- **[Male CNS · HHMI Janelia](https://male-cns.janelia.org/)** — 공식 v1.0 원본. [Berg et al., 수컷 초파리 중추신경계 커넥톰 연구](https://pmc.ncbi.nlm.nih.gov/articles/PMC12636603/).

---

<div align="center">
<sub>NeuroFly · 감각에서 뉴런으로, 뉴런에서 화면 속 움직임으로.</sub>
</div>
