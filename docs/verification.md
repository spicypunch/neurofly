# 검증 기록

2026-10-02 KST · Apple M1 Pro · macOS 26.1 · Swift 6.2

아래 값은 이 프로젝트의 로컬 실행 기록입니다. 공개 연구의 생물학적 검증 결과와
구분하며, 같은 조건을 다시 실행할 수 있도록 명령과 범위를 남깁니다.
수치 요약은 [verification-summary.json](verification-summary.json)에 있습니다.

## 코어 테스트

```sh
python3 scripts/fetch-data.py
swift test -c release
```

**29 tests, 0 failures** — BodyState 6개, BrainEngine 10개, World 13개.

- 고정된 실제 연결 데이터의 뉴런 수·edge 수·입출력 매핑
- 같은 seed로 초기화했을 때 동일한 신경 출력
- 같은 시간축의 무자극 대조군과 비교한 단맛 반응
- 그림자·접촉에서 신경망을 거쳐 증가하는 회피 출력
- 외부 감각을 모두 차단했을 때 무자극 대조군과 같은 출력
- 같은 신경·운동 출력을 주면 먹이 위치가 달라도 같은 이동
- 섭식 출력과 물리적 접촉이 함께 있을 때만 먹이 소비
- 일시정지, 유효하지 않은 좌표, 월드 크기 변경
- 약한 0.12 / 0.15 냄새가 projection 뉴런까지 도달하는지 확인
- PN 활동 감소가 bounded search를 시작하고 보정 재초기화가 history를 지우는지 확인
- 섭식이 search를 중단하고, 무신경 입력이 search를 계속시키지 않는지 확인
- 속도에 따른 허기 증가, 실제 섭취량 accounting, 0.20 / 0.60 motivation hysteresis
- pause / reset에서 허기와 누적 섭취 상태가 올바르게 유지·초기화되는지 확인

## 허기 cycle

```sh
mkdir -p artifacts
swift run -c release NeuroFly --hunger > artifacts/hunger.json
python3 scripts/verify-hunger.py artifacts/hunger.json
```

확정 기록은 `artifacts/hunger-cycle.json`입니다. seed 42, 2,560 × 1,400 공간,
초기 hunger 0.65에서 첫 먹이를 먹고 포만 상태에 들어간 뒤, 음식을 치우고 자연 회복한
다음 두 번째 먹이를 배치하는 214.366초 cycle입니다.

| 단계 | 기록 |
| :--- | :--- |
| 첫 먹이 포만 전환 | 12.466초 · hunger 0.19983 · 0.396435개 섭취 · 남은 음식 0.603565 |
| 포만 5초 후 정리 | 17.466초 · 남은 음식 0.5905 · 첫 먹이 누적 섭취 0.4095개 |
| 자연 회복 후 재배치 | 200.566초 · hunger 0.60004 · 회복 183.1초 · 새 먹이는 월드 중심 방향 120px에 배치 |
| 두 번째 먹이 포만 전환 | 214.366초 · 0.3575개 섭취 · 누적 0.767개 · final hunger 0.19954 |
| PN 반응 | 허기 상태 최대 875.08 Hz · 포만 2초 후 약 0.000037 Hz |

허기는 `BodyState`의 공학적 game mechanic입니다. 모델 시간 1초마다
`0.002 + 0.0005 × min(1, speed / 120)`만큼 증가하고, 실제 섭취량의 1.2배만큼 감소합니다.
hunger가 0.20 이하이면 food drive를 끄고, 0.60 이상이면 다시 켜며 중간 구간은 이전 상태를 유지합니다.
`foodDrive`는 ORN·단맛 외부 입력만 조절하고 그림자·접촉에는 영향을 주지 않습니다.
음식을 치운 뒤 body 상태가 변하지 않았고, 뇌에는 먹이 좌표를 전달하지 않았습니다.
이는 생물학적 hunger circuit, 대사, food-seeking 행동의 재현이 아닙니다.

## 먹이 탐색 grid

### 허기 도입 전 historical

`artifacts/foraging-lookup.json`과 `artifacts/foraging-warm.json`은 BodyState를 넣기 전 기록입니다.
seed 42, 2,560 × 1,400 공간에서 거리 120 / 220 / 360 × 방위 0 / ±45 / ±90 / 180,
총 18개를 두 번 실행해 36조건을 확인했습니다.

- 기본 run: 18 / 18 접촉·섭취, 15 / 18 전량 소비, 접촉 2.933–19.4초
- 뇌 무입력 10초 warmup run: 같은 초기 몸체 위치에서 18 / 18 접촉·섭취, 접촉 2.2–25.266초
- 각 run 감각 차단 대조 3개: no-food 신경 출력·몸체 궤적과 정확히 일치

이 수치는 현재 포만 동작이 추가되기 전의 historical 결과입니다. 현재 최종 탐색 성능의 수치로
해석하지 않습니다.

### 현재 허기 반영 run

확정 기록은 `artifacts/foraging-hunger.json`입니다. 같은 seed 42, 2,560 × 1,400 공간,
거리 120 / 220 / 360 × 방위 0 / ±45 / ±90 / 180의 18조건을 30초씩 실행했습니다.

- 18 / 18 조건에서 접촉
- 18 / 18 조건에서 먹이 일부 섭취(남은 양 감소)
- 접촉 시간 2.633–27.333초
- 섭취량 비율 0.1755–0.427; 포만 상태에 들어간 뒤에는 일부 먹이가 남을 수 있음
- 감각 차단 대조 3개는 no-food와 body·neural trajectory digest가 모두 정확히 일치

검증 명령은 다음과 같습니다.

```sh
swift run -c release NeuroFly --foraging > artifacts/foraging-hunger.json
python3 scripts/verify-foraging.py artifacts/foraging-hunger.json --require-full-grid --require-contact
```

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
조절이며, 뇌 공간의 biological hunger circuit, 기억 상태, 학습은 현재 구현하지 않았습니다.

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

- ad hoc 코드 서명 검증 통과
- 임시 폴더로 복사한 `.app`의 실제 그래프 로딩 및 계산 성공
- 커널이나 데이터가 빠진 복사본에서 정상 오류 반환 — 개발 폴더로 조용히 대체하지 않음
- 기본 실행에서 큰 창·컨트롤 패널 없이 펫 오버레이 표시 확인
- 상태 창 렌더링 확인; README의 `neural-status.png`는 기존 캡처이며 최신 메뉴 흐름 전체의 UI 자동화는 시스템 메뉴바 접근 제한으로 미완료
- 날개를 몸통 뒤쪽으로 뻗도록 수정 후 화면 확인 및 전체 회전 범위의 기하 확인

## 원저자 모델과의 관계

[별도 재현 도구](../tools/reference/README.md)는 원저자의 v630 Brian2 모델로
무자극·sugar 100Hz·sugar 150Hz 조건을 실행합니다. 이 기준 실험은 앱의 v783 Metal 모델과
수치적으로 동일하다는 증거가 아닙니다. 현재 앱은 baseline, gain, 감각 부호화 및
2D 운동 변환을 추가한 별도의 공학적 모델입니다.
