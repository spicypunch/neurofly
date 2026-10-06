# 검증 기록

2026-10-06 KST · Apple M1 Pro · macOS 26.1 · Swift 6.2

아래 값은 이 프로젝트의 로컬 실행 기록입니다. 공개 연구의 생물학적 검증 결과와
구분하며, 같은 조건을 다시 실행할 수 있도록 명령과 범위를 남깁니다. 현재 release unit test는
67개가 통과했습니다. FlyWire v783의 hunger·foraging·learning·population 통합 gate와 Male CNS의
hunger·learning·foraging·population·probe 통합 gate가 현재 산출물에서 통과했습니다. signed release
app과 native GUI의 26개 확인 항목도 통과했으며, 이전 허기·먹이 기록은 비교 가능한 historical
조건으로 보존합니다.
수치 요약은 [verification-summary.json](verification-summary.json)에 있습니다.
FlyWire 허기·개체군 산출물은 2026-10-02 기록을 유지했습니다. 코어 테스트, 두 모델의
먹이 탐색·학습, Male CNS 허기·개체군·probe, 최종 앱 확인은 2026-10-06 기록입니다.

## 데이터셋과 이용 조건

| 모델 | 그래프 규모 | 이용 조건 |
| :--- | :--- | :--- |
| FlyWire FAFB v783 | 139,255 neurons · 15,091,983 directed edges · 54,492,922 aggregated synapses | [CC BY-NC 4.0](https://creativecommons.org/licenses/by-nc/4.0/) |
| Male CNS v1.0 | 166,700 annotated bodies · 25,582,938 internal edges · 124,177,617 synapses | [CC BY 4.0](https://creativecommons.org/licenses/by/4.0/) |

두 모델의 원본과 파생 compact graph는 서로 다른 데이터셋과 이용 조건으로 배포합니다.
Male CNS의 source row 경계, attribution, signed-weight 정책은 [`data/malecns/DATA_LICENSE.md`](../data/malecns/DATA_LICENSE.md)에 기록했습니다.

## 다운로드 배포본 — 2026-10-06

`scripts/package-release.sh`로 macOS 15 이상, Apple Silicon 전용 0.2.0 ZIP을 생성했습니다.
ZIP은 129,131,788 bytes이며 앱, 설치 안내, 데이터·원 코드 고지를 포함합니다.
별도의 SHA-256 확인 파일도 생성합니다.

ZIP을 저장소 밖의 임시 폴더에 풀고 다음을 확인했습니다.

- 압축 해제 후 `codesign --verify --deep --strict` 통과
- `arm64` 실행 파일, 최소 macOS 15.0, 실행 권한 유지
- 저장소 데이터 경로를 지정하지 않고 앱에 포함된 두 모델의 `--probe` 실행
- FlyWire 139,255 neurons / 15,091,983 edges, Male CNS 166,700 / 25,582,938 로딩
- 설치 안내, FlyWire·Male CNS 데이터 이용 조건과 SiliconFly 고지 포함
- 생성 ZIP의 SHA-256 확인 통과

현재는 **ad hoc 서명이며 Apple 공증을 받지 않았습니다.** 서명 무결성 검사는 Developer ID나
Gatekeeper의 배포 승인을 의미하지 않습니다. 다운로드 격리가 적용된 앱의 첫 GUI 실행을
다른 Mac에서 확인하지는 않았습니다. [설치 안내](install.md)에 Apple의 앱별 허용 절차를 기록했습니다.

배포 파일의 크기·SHA-256과 검사 결과는 [verification-summary.json](verification-summary.json)의
`distribution`에 있습니다. 기존 26개 GUI 확인은 이 소스의 로컬 실행 기록입니다.

## 코어 테스트

```sh
python3 scripts/fetch-data.py
swift test -c release
```

**현재 확인된 release unit tests: 67 tests, 0 failures** — BodyState 6개, BrainEngine 10개,
BrainModel 9개, ColonyStore 4개, FlyMemory 14개, PopulationWorld 9개, World 15개.

- 고정된 실제 연결 데이터의 뉴런 수·edge 수·입출력 매핑
- 같은 seed로 초기화했을 때 동일한 신경 출력
- 같은 시간축의 무자극 대조군과 비교한 단맛 반응
- FlyWire의 그림자·접촉에서 신경망을 거쳐 증가하는 회피 출력
- 외부 감각을 모두 차단했을 때 무자극 대조군과 같은 출력
- 같은 신경·운동 출력을 주면 먹이 위치가 달라도 같은 이동
- 섭식 출력과 물리적 접촉이 함께 있을 때만 먹이 소비
- 일시정지, 유효하지 않은 좌표, 월드 크기 변경
- 약한 0.12 / 0.15 냄새가 projection 뉴런까지 도달하는지 확인
- PN 활동 감소가 bounded search를 시작하고 보정 재초기화가 history를 지우는지 확인
- 섭식이 search를 중단하고, 무신경 입력이 search를 계속시키지 않는지 확인
- 속도에 따른 허기 증가, 실제 섭취량 accounting, 0.20 / 0.60 motivation hysteresis
- pause / reset에서 허기와 누적 섭취 상태가 올바르게 유지·초기화되는지 확인

## 현재 두 모델의 gate 요약

| 검증 항목 | 현재 기록 |
| :--- | :--- |
| 허기 cycle | **PASS** — 208.033 model seconds · 첫 먹이 0.40508개 · 두 번째 0.35100개 · 누적 0.75608개 |
| 먹이 탐색 | **PASS** — 18/18 접촉·양의 섭취량 · 감각 차단 3개 대조군이 no-food와 일치 |
| 먹이 기억 | **PASS** — 실제 섭취 보상, gain·graph response·movement·persistence·reversal·forgetting |
| 개체군 | **PASS** — 2·4개 독립 뇌와 memory/touch isolation · realtime factor 5.0288× / 2.2222× |
| 개체군 메모리 | peak process resident memory 685,162,496 bytes · 2개 사례에도 4개 engine 할당 상태 |
| Male CNS hunger cycle | **PASS** — 198.866 model seconds · 첫 먹이 0.394485개 · 두 번째 0.348790개 |
| Male CNS learning assay | **PASS** — 실제 섭취·학습·graph response·movement·persistence·reversal·forgetting checks 통과 · mixed-food baseline은 바나나/1,194.397px, 학습 상태는 베리/1,002.586px |
| Male CNS 먹이 탐색 grid | **PASS** — 18/18 접촉·양의 섭취량 · 접촉 1.9–29.666초 · 섭취량 0.002145–0.43979개 · 감각 차단 3개 대조군이 no-food와 일치 |
| Male CNS 개체군 | **PASS** — 2·4개 독립 뇌·memory/touch isolation·공용 먹이 보존·pause/raw 보존 · realtime factor 2.3603× / 1.1861× · peak process resident memory 1,261,174,784 bytes · 4개 사례의 2번 개체는 섭취 0 |
| Male CNS probe | **PASS** — 166,700 neurons / 25,582,938 edges · blocked 입력의 신경 출력이 baseline과 일치 · 좌우 fruit relay·taste feeding·loom escape 응답 확인 · touch mapping 37개는 연결되지만 명확한 운동 효과는 입증하지 않음 |
| Male CNS 전체 동적 행동 | **PASS** — hunger·learning·18조건 foraging·population·probe 통합 gate 통과 |

## Native GUI smoke check

`artifacts/gui-evolution.json`은 2026-10-06 KST에 `dist/NeuroFly.app`을 native AppKit/CUA로
실행해 확인한 화면·상호작용 기록입니다. 26개 확인 항목이 모두 통과했고 `notYetVerified`는
비어 있습니다. GUI 자체는 Male CNS의 생물학적 행동을 증명하는 자료가 아니지만, 최종 behavior
bundle rebuild·서명과 앱 상호작용은 확인되었습니다.

| 확인 범위 | 현재 기록 |
| :--- | :--- |
| 시작 화면과 단축키 | **PASS** — 큰 창 없이 데스크톱 펫으로 시작 · `⌘L` 실험실 열기 · `⌘B` 상태 보기 · `⌘P` 일시정지/다시 시작 · `전체 초기화`와 `다시 시작` 라벨 구분 |
| 상태 창 레이아웃 | **PASS** — 처음 열 때 상단에서 시작하고, 폭 382px에서 섹션 제목·설명이 왼쪽으로 정렬됨 |
| 개체군 조작 | **PASS** — 두 번째·세 번째 개체 추가, 1–4 선택, 네 번째까지 추가, 다섯 번째 추가 비활성화, 선택 개체 제거 · 준비 중 컨트롤 비활성화 |
| 선택 개체 학습 | **PASS** — 선택한 개체의 학습 토글이 다른 개체의 설정을 바꾸지 않음 |
| 모델 전환 | **PASS** — 두 개체 상태에서 FlyWire ↔ Male CNS 양방향 전환 · Male CNS counts 166,700 / 25,582,938 표시 · pause와 learning 설정 유지 · 전체 초기화 뒤 시계 재개 |
| 저장 후 재실행 | **PASS** — 저장된 모델·profile을 포함한 checkpoint가 재실행 뒤에도 정확히 복원됨 · 실험실을 닫으면 펫만 남음 · 두 모델 패키지와 서명 확인 |

이 GUI 기록은 화면·상호작용과 최종 signed bundle을 확인한 자료입니다. Male CNS의 동적 행동
수치는 별도의 headless 산출물에 기록되어 있으며, GUI 확인만으로 생물학적 회로 재현을 주장하지 않습니다.

## 허기 cycle

```sh
mkdir -p artifacts
swift run -c release NeuroFly --hunger --model flywire-v783 > artifacts/hunger-flywire.json
python3 scripts/verify-hunger.py artifacts/hunger-flywire.json
```

확정된 현재 기록은 `artifacts/hunger-flywire.json`입니다. FlyWire v783, seed 42,
2,560 × 1,400 공간, 초기 hunger 0.65에서 첫 먹이를 먹고 포만 상태에 들어간 뒤,
음식을 치우고 자연 회복한 다음 두 번째 먹이를 배치하는 208.033초 cycle입니다.

| 단계 | 기록 |
| :--- | :--- |
| 첫 먹이 포만 전환 | 12.433초 · hunger 0.19976 · 0.396435개 섭취 · 남은 음식 0.603565 |
| 포만 후 정리 | 17.433초 · 첫 먹이 누적 섭취 0.40508개 · 정리 전 남은 양 0.59492 |
| 자연 회복 후 재배치 | 198.633초 · hunger 0.60006 · 회복 181.2초 · 새 먹이는 월드 중심 방향에 배치 |
| 두 번째 먹이 포만 전환 | 208.033초 · 0.35100개 섭취 · 누적 0.75608개 · final hunger 0.19823 |
| PN 반응 | 허기 상태 최대 900.76 Hz · 포만 정착 후 약 0.00003998 Hz |

허기는 `BodyState`의 공학적 game mechanic입니다. 모델 시간 1초마다
`0.002 + 0.0005 × min(1, speed / 120)`만큼 증가하고, 실제 섭취량의 1.2배만큼 감소합니다.
hunger가 0.20 이하이면 food drive를 끄고, 0.60 이상이면 다시 켜며 중간 구간은 이전 상태를 유지합니다.
`foodDrive`는 ORN·단맛 외부 입력만 조절하고 그림자·접촉에는 영향을 주지 않습니다.
음식을 치운 뒤 body 상태가 변하지 않았고, 뇌에는 먹이 좌표를 전달하지 않았습니다.
이는 생물학적 hunger circuit, 대사, food-seeking 행동의 재현이 아닙니다.

비교용 historical BodyState baseline은 214.366초 cycle이었고, 첫 먹이 0.4095개·두 번째
0.3575개·누적 0.767개, PN 최대 875.08 Hz를 기록했습니다. 이 값은 현재 FlyWire gate의 결과가
아니라 이전 구현의 기록으로 보존합니다.

## 기억·개체군·뇌 모델 — FlyWire와 Male CNS 검증

아래는 현재 작업 트리에 들어온 확장 기능의 경계입니다. 새 기능은 고정된 연결 그래프와
2D 몸체 주위의 공학적 adapter이며, 생물학적 기억·학습·Male CNS 행동을 재현한다는 뜻이 아닙니다.
67개 release unit test와 FlyWire v783의 `--learning`, `--population` integration gate는 통과했습니다.
foraging·hunger gate도 같은 FlyWire 모델에서 통과했습니다. Male CNS의 hunger·learning·foraging·population·probe
통합 gate도 PASS이며, 이 결과는 아래 산출물과 현재 signed release에 대응합니다.

### 먹이 연합 기억

- 가상 먹이 종류는 **바나나**와 **베리**입니다.
- 양의 연합은 냄새나 단맛 감지가 아니라, 접촉 뒤 실제로 줄어든 음식량에서만 발생합니다.
- 최근 단서와 함께 발생한 그림자·접촉은 해당 먹이 연합을 낮춥니다. eligibility trace는 3초,
  망각 시간 상수는 600초이며, 각 먹이 gain은 0.15–2.0 범위로 제한합니다.
- 학습값은 raw 감각 스냅샷을 덮어쓰지 않고 냄새 입력 adapter에만 적용한 뒤 실제 `BrainEngine`에
  입력됩니다. 단맛·그림자·접촉 채널과 연결 가중치는 그대로 보존합니다.
- learning을 끄면 입력 gain은 중립값 1로 동작하지만 이미 저장된 연합값은 보존합니다.
  선택 개체 기억 지우기는 해당 profile만 초기화하고, 전체 초기화는 모든 개체의 몸체와 기억을
  시작값으로 되돌립니다.

FlyWire v783의 learning gate는 실제 섭취 보상, 냄새 gain, graph response·movement 변화,
learning-off 중립, raw 감각 보존, persistence, 위협 반전·망각을 모두 확인했습니다.
두 먹이 30초 assay는 receptor saturation을 피하려고 두 먹이를 각각 반 정도 채운 상태에서
시작했습니다. learning off/on 모두 첫 소비는 바나나였고, path distance는 1,159.776px 대
1,260.448px로 100.671px 달랐습니다. 이는 신경 반응과 궤적의 변조를 보여주는 결과이지,
더 나은 먹이 선호나 생물학적 학습의 재현을 뜻하지 않습니다. 이 first-consumption 결과는
FlyWire run에 한정됩니다.

`artifacts/learning-malecns-final.json`의 Male CNS learning assay도 같은 checks를 통과했습니다.
mixed-food baseline은 바나나를 먼저 먹고 path 1,194.397px, 학습 상태는 베리를 먼저 먹고 path
1,002.586px를 기록했습니다. 이는 신경 반응·궤적·선택의 변조를 보여주는 결과이지 향상된 먹이
선호를 입증하지 않습니다.

### 독립 개체군

- 1–4개 개체가 각각 ID, deterministic seed, 몸체, `MotorDecoder`, 기억, 독립 `BrainEngine`을 가집니다.
  FlyWire gate에서 2·4개 사례 모두 독립 뇌, memory/touch isolation, 공용 먹이 보존, pause 고정을
  확인했습니다. realtime factor는 각각 5.0288×와 2.2222×였습니다.
  두 사례의 peak process resident memory는 685,162,496 bytes였으며, 2개 사례에서도 4개 engine이
  할당된 상태의 peak입니다. runtime factor와 메모리는 GUI·startup을 제외한 진단 프로세스 측정입니다.
- 먹이와 그림자는 공용 canonical environment를 사용하고, 접촉은 선택한 개체에만 전달합니다.
  음식량은 한 공용 목록에서 차감하므로 개체별 섭취 합계가 환경의 감소량을 넘지 않아야 합니다.
- 새 개체는 허기 0.65의 새 몸체와 새 신경 상태로 추가되며, 현재 환경·먹이·그림자 시점에는
  합류합니다. 상태 창과 데스크톱 메뉴는 선택 개체를 기준으로 갱신합니다.

### 저장과 모델 전환

- 기본 저장 파일은 `Application Support/NeuroFly/colony-v1.json`입니다.
  `brainModel`, 선택 개체 ID, 각 profile의 ID·ordinal·seed·기억만 저장하며, 먹이 좌표·몸체·막전압·
  simulation clock은 저장하지 않습니다. 재시작 시 몸체는 허기 0.65와 빈 환경으로 시작하고
  학습된 기억만 복원합니다.
- 모델 enum은 `flywire-v783`과 `malecns`를 가집니다. 데스크톱 GUI는 저장된
  `colony-v1.json`의 모델 선택을 먼저 사용하고, 저장 선택이 없는 fresh 설정에서는 Male CNS가
  준비되어 있으면 이를 우선하며 없을 때만 FlyWire를 선택합니다. CLI 진단은 `--model` 또는
  `NEUROFLY_MODEL`을 지정하지 않으면 FlyWire를 사용합니다. 모든 경로는 실제 manifest와 compact
  binary가 준비된 모델만 선택하며, 선택한 모델이 없거나 manifest가 맞지 않으면 다른 그래프로
  조용히 fallback하지 않고 전환을 거부합니다.
  모델 전환은 모든 개체의 새 뇌와 calibration을 준비한 뒤 적용하고, 환경·몸체·기억은 보존하면서
  새 neural observation과 막전압은 초기화합니다. 준비에 실패하면 이전 개체군을 유지합니다.
- Male CNS v1.0 원본은 Janelia의 공식 `body-annotations`, `body-neurotransmitters`,
  `connectome-weights` Feather 세 파일(약 1.1 GB raw)에서 compact graph로 import했습니다.
  211,577개 annotation row 중 166,700개 annotated body를 사용하고, 151,856,684개 source
  connection row에서 25,582,938개 internal edge와 124,177,617개 synapse를 보존했습니다.
  annotated 경계 밖 126,273,746개 row는 제외했으며 signed weight 범위는 -2591–1878이고
  clipping은 하지 않았습니다. attribution·원본 pin·histamine 부호 가정은
  [`data/malecns/DATA_LICENSE.md`](../data/malecns/DATA_LICENSE.md)에 기록했습니다.
  데이터 import와 Male CNS hunger·learning·foraging·population·probe 통합 gate는 완료되었습니다.
  개체군 4개 사례에서는 2번 개체가 섭취하지 않았으므로 모든 개체의 섭취를 주장하지 않습니다.
  FlyWire 파생 데이터의 [CC BY-NC 4.0](https://creativecommons.org/licenses/by-nc/4.0/)과
  Male CNS 원본의 [CC BY 4.0](https://creativecommons.org/licenses/by/4.0/)은 서로 다른 이용 조건입니다.

### 확장 검증 명령

새 clone에서도 다음처럼 importer 의존성을 격리할 수 있습니다. Python 3.11과 저장소의
`scripts/requirements-malecns.txt`를 사용하며, 현재 compact import는 완료되어 있습니다.
아래 FlyWire 통합 명령과 Male CNS의 hunger·learning·foraging·population·probe 명령은 현재 PASS
기록을 재현합니다.

```sh
python3.11 -m venv .venv-malecns
.venv-malecns/bin/python -m pip install -r scripts/requirements-malecns.txt
.venv-malecns/bin/python scripts/fetch-malecns.py --download-only
.venv-malecns/bin/python scripts/fetch-malecns.py --import

swift run -c release NeuroFly --learning --model flywire-v783 > artifacts/learning-flywire.json
python3 scripts/verify-evolution.py artifacts/learning-flywire.json --learning
swift run -c release NeuroFly --population --model flywire-v783 > artifacts/population-flywire.json
python3 scripts/verify-evolution.py artifacts/population-flywire.json --population
swift run -c release NeuroFly --hunger --model malecns > artifacts/hunger-malecns-final.json
swift run -c release NeuroFly --learning --model malecns > artifacts/learning-malecns-final.json
swift run -c release NeuroFly --foraging --model malecns > artifacts/foraging-malecns-final.json
swift run -c release NeuroFly --population --model malecns > artifacts/population-malecns-final.json
swift run -c release NeuroFly --probe --model malecns > artifacts/probe-malecns-final.json
```

`verify-evolution.py --learning`은 실제 섭취 보상, graph response·movement 변화, learning-off 중립,
raw 감각 보존, checkpoint round-trip, 위협 반전·망각을 검사합니다. `--population`은 2·4개 독립 뇌,
공용 음식 보존, 기억 격리, 선택 접촉, pause 고정, raw 감각 보존을 검사합니다. 두 FlyWire 명령은
현재 PASS이며, Male CNS의 hunger·learning·foraging·population·probe 결과도 기록했습니다. 전체
runtime gate는 `artifacts/`의 최종 산출물과 signed release bundle에서 확인되었습니다.

## 먹이 탐색 grid

### 현재 FlyWire v783 run

확정 기록은 `artifacts/foraging-flywire.json`입니다. FlyWire v783, seed 42, 2,560 × 1,400 공간,
Gaussian 냄새장(σ=180), 거리 120 / 220 / 360 × 방위 0 / ±45 / ±90 / 180의 18조건을
30초씩 실행하고 0.5초 기본 neural warmup을 사용했습니다.

- **18 / 18 조건에서 접촉하고 18 / 18 조건에서 양의 섭취량**을 기록했습니다.
- 접촉 시간은 2.633–27.333초, 섭취량 비율은 0.1711–0.4354였습니다.
- 감각 차단 대조 3개는 no-food body·neural trajectory digest와 정확히 일치했습니다.
- 포만 상태에 들어가면 음식 일부가 남을 수 있으므로 이 gate의 consumption은 전량 소비를 뜻하지 않습니다.

검증 명령은 다음과 같습니다.

```sh
swift run -c release NeuroFly --foraging --model flywire-v783 > artifacts/foraging-flywire.json
python3 scripts/verify-foraging.py artifacts/foraging-flywire.json --require-full-grid --require-contact
```

### 현재 Male CNS v1.0 run

`artifacts/foraging-malecns-final.json`은 같은 18조건 grid에서 **18 / 18 접촉·양의 섭취량**을
기록했습니다. 접촉 시간은 1.9–29.666초, 섭취량은 0.002145–0.43979개였습니다. 30초 종료 직전
접촉한 조건에서 섭취량이 작을 수 있으므로 이 결과는 충분한 식사량이나 최단 경로를 보장하지
않습니다. 감각 차단 대조 3개는 no-food neural/body digest와 일치했습니다.

이 Male CNS foraging 결과는 탐색·섭취 경로가 연결 그래프와 현재 decoder 조건에서 작동하는지
확인한 gate입니다. population과 probe 결과를 포함한 전체 Male CNS 동적 행동 gate가 통과했으며,
30초 종료 직전 접촉으로 섭취량이 작을 수 있다는 범위는 그대로 적용됩니다.

### 허기 도입 전 historical

`artifacts/foraging-lookup.json`과 `artifacts/foraging-warm.json`은 BodyState를 넣기 전 기록입니다.
seed 42, 2,560 × 1,400 공간에서 거리 120 / 220 / 360 × 방위 0 / ±45 / ±90 / 180,
총 18개를 두 번 실행해 36조건을 확인했습니다.

- 기본 run: 18 / 18 접촉·섭취, 15 / 18 전량 소비, 접촉 2.933–19.4초
- 뇌 무입력 10초 warmup run: 같은 초기 몸체 위치에서 18 / 18 접촉·섭취, 접촉 2.2–25.266초
- 각 run 감각 차단 대조 3개: no-food 신경 출력·몸체 궤적과 정확히 일치

이 수치는 현재 포만 동작이 추가되기 전의 historical 결과입니다. 현재 최종 탐색 성능의 수치로
해석하지 않습니다.

### 허기 도입 직후의 비교 기록

`artifacts/foraging-hunger.json`은 현재 FlyWire gate 전의 비교 기록입니다. 같은 18조건에서
18 / 18 접촉·양의 섭취량, 접촉 2.633–27.333초를 보였지만, 현재 결과의 기준 산출물은
`foraging-flywire.json`입니다.

접촉은 몸체 중심이 아닌 입 위치에서 계산하며, 모든 seed·배치에서 최단 경로나 안정적인 탐색을 보장하지 않습니다.

## 입력 adapter와 방향 lookup

외부 냄새 입력은 좌우 ORN에만 들어갑니다. 현재 adapter는 좌우 입력의 `sqrt(mean)` 크기와
좌우 대비 10배를 사용하고, ORN drive를 최대 0.22로 제한합니다. 두 DM1_lPN 값은 외부 입력을
그대로 복사한 값이 아니라 연결 그래프에서 발생한 spike 기반 발화율입니다.

대칭 농도 보정과 별도로, 5개 공통 농도 × 3개 좌우 대비로 총 15개 probe를 실행해 두 PN
발화율의 실측 lookup을 만들고 선회 방향을 해석합니다. 냄새 입력이 일정 시간 약해지면
디코더가 뉴런 출력 이력만으로 최대 1.8초의 재탐색 선회를 적용합니다. 이 보정은 재현 가능한
2D 몸체 adapter이며, 생물학적으로 검증된 food-seeking 회로를 재현한다는 의미가 아닙니다.
`MotorDecoder`는 food coordinate나 raw sensory input을 받지 않습니다.

상태 창은 감각 입력, DM1_lPN 후각 중계, 운동 뉴런 원시 발화율, 디코더가 적용한 실제 몸체
출력, 허기·먹이 반응·누적 섭취를 별도로 표시합니다. 허기는 몸 상태에만 있는 공학적
조절이고, 먹이 기억은 연결 그래프 밖의 앱 수준 adapter입니다. 상태 창과 메뉴에는 선택 개체,
모델, 기억 gain·섭취 통계와 학습 스위치가 추가되지만, 생물학적 hunger circuit이나 synaptic
plasticity를 구현했다는 뜻은 아닙니다.

Male CNS의 `synapses.bin`에는 import한 signed edge weight가 들어가지만, 런타임은
`MetalBrainSimulation`의 fixed-point 양자화와 dataset-specific gain을 적용합니다. Male CNS
whole-network weight gain은 **0.525**, PN sensory/background gain은 **0.05 / 0.02**, taste gain은
**0.75**, DNp09 tonic baseline은 **0.100**입니다. relay 활성화 threshold는 가장 약한 bilateral
probe를 기준으로 **8–30 Hz** 범위에서 측정하고, MN9 feeding threshold는 측정된 baseline·odor-only
envelope와 taste+odor 응답 사이 midpoint입니다. decoder는 2.5초 neural plume memory,
350ms 방향 smoothing, MN9 100ms evidence 또는 threshold+5 Hz 조건, 약한 plume loss 뒤 0.3초
재탐색, 강한 active plume의 stable course 1초·관찰 1.5초 조건을 사용합니다. Male PN steering
gain은 **1.3**, 애매한 PN readout의 descending fallback gain은 **0.055**이며 legacy FlyWire
decoder는 유지합니다. 따라서 raw binary weight는 실제 source-derived 값이지만 런타임에서
모든 원본 weight 비율을 보정 없이 그대로 재생하는 것은 아니고, 학습이나 decoder가 raw graph를
수정하지도 않습니다. 이 값들은 생물학적 postsynaptic efficacy가 아니라 Male CNS용 공학적
operating point입니다.

## 계산 성능

```sh
swift run -c release NeuroFly --benchmark
```

| 항목 | 측정 |
| :--- | ---: |
| 계산한 뇌 시간 | 10초 |
| 계산 루프의 실제 시간 | 0.965초 |
| 뇌 시간 / 실제 시간 | 10.36배 |
| 프로세스 최대 resident memory | 245,743,616 bytes · 약 234 MiB |

위 값은 허기 도입 전 `--benchmark`에서 기록한 이전 headless 측정이며, 계산 시간은 그래프 초기화를 제외합니다.
현재 최종 GUI·runtime 성능과 동일한 값으로 표시하지 않습니다.
메모리는 `/usr/bin/time -l`로 프로세스 전체에서 측정했습니다.
GUI 렌더링, 다른 하드웨어, 배터리와 장시간 발열은 이 수치에 포함되지 않습니다.

## 배포 패키지와 화면

- `scripts/build-app.sh` v0.2.0은 FlyWire와 Male CNS의 검증된 compact data가 모두 있을 때만 패키지를 만듭니다.
  두 compact data가 없거나 무결성이 맞지 않으면 missing-data 오류로 중단되는 fail-closed 동작입니다.
  현재 Male CNS compact import는 완료되었고, 이 항목은 data gate를 기록합니다.
- ad hoc 코드 서명 검증 통과
- 임시 폴더로 복사한 `.app`의 실제 그래프 로딩 및 계산 성공
- 커널이나 데이터가 빠진 복사본에서 정상 오류 반환 — 개발 폴더로 조용히 대체하지 않음
- 기본 실행·메뉴 단축키·상태 창·실험실의 최신 native GUI 확인은 로컬 `artifacts/gui-evolution.json`과 공개 [verification-summary.json](verification-summary.json)의 `evolution.nativeGUI`에 기록
- 위 GUI 확인은 모델 전환과 개체군 조작을 포함하지만 Male CNS 동적 행동의 PASS를 의미하지 않음
- 날개를 몸통 뒤쪽으로 뻗도록 수정 후 화면 확인 및 전체 회전 범위의 기하 확인

## 원저자 모델과의 관계

[별도 재현 도구](../tools/reference/README.md)는 원저자의 v630 Brian2 모델로
무자극·sugar 100Hz·sugar 150Hz 조건을 실행합니다. 이 기준 실험은 앱의 v783 Metal 모델과
수치적으로 동일하다는 증거가 아닙니다. 현재 앱은 baseline, gain, 감각 부호화 및
2D 운동 변환을 추가한 별도의 공학적 모델입니다.

현재 진단 baseline 수치는 FlyWire FAFB v783에서 나온 값입니다. 데스크톱 GUI의 fresh 설정은
Male CNS가 준비되어 있으면 이를 우선하고, 저장된 모델 선택이 있으면 그 선택을 먼저 복원합니다.
Male CNS v1.0은 별도 `malecns` 모델과 명시적 neural mapping 경계를 갖습니다. 공식 원본 Feather에서
166,700개 annotated body,
25,582,938개 internal edge, 124,177,617개 synapse를 가진 compact CSR graph를 만들었고,
원본 151,856,684개 connection row 중 126,273,746개는 annotated 경계 밖이라 제외했습니다.
signed weight는 -2591–1878이며 clipping하지 않았습니다. counts·license attribution·histamine 부호
가정은 [`data/malecns/DATA_LICENSE.md`](../data/malecns/DATA_LICENSE.md)에 기록했습니다.
이 데이터 확인은 Male CNS food/learning/runtime 행동의 PASS를 의미하지 않으며, 통합 gate는 별도입니다.
