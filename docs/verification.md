# 검증 기록

## 자동 검증

2026-09-28, macOS 26.3.1 / Apple Silicon / Swift 6.3.3 환경.

- `python3 scripts/verify.py`: exit 0. 내부 `swift test --jobs 2` 32개 테스트 통과, `python3 scripts/build.py` exit 0. release 앱 번들 빌드와 `codesign --verify --strict` 성공.
- 날짜 모델 8개, 메뉴막대 날짜·로그인 상태·기준점 13개, 일정 접근 6개, 화면 상태·제스처 계산 5개다.
- 구현 전 해당 타입이 없어 실패한 테스트(exit 1)를 확인한 뒤 구현했다. 가짜 backend는 사용자 일정과 로그인 항목을 변경하지 않는다.

## 발견 후 수정한 항목

- `Sources/CalendarCore/CalendarState.swift`의 격자 계산: America/Asuncion 2023-10을 조회하면 날짜에 01:00이 전파되어 마지막 날 다음 날짜의 첫 한 시간까지 조회했다. 각 날짜의 하루 시작 정규화로 수정했고 회귀 테스트의 실패→통과를 확인했다.
- `Sources/CalendarCore/EventOccurrence.swift`의 빈 제목: 괄호가 빠진 표시를 명세의 '(제목 없음)'으로 수정했고 테스트 통과를 확인했다.
- `Sources/CalendarBar/main.swift`의 초기화: Swift Package 진입점에서 main-actor delegate를 직접 초기화하면 통합 빌드 exit 1이었다. 명시적 main actor 문맥과 delegate 수명 유지로 수정 후 전체 검증 exit 0.

## 실제 실행과 한계

- 제한 시간을 둔 `CalendarBar --smoke --show` 프로세스 실행과 앱 시작 콜백을 확인했다. 스택 표본은 NSApplication 이벤트 루프 대기를 보였다. 이는 화면 정상 동작 증거가 아니다.
- 컴퓨터 사용 도구의 앱 bundle ID/절대 경로 접근은 `timeoutReached`로 실패했다. Finder 접근성 조회는 가능했지만 화면 캡처는 흰 화면이었다. 이후 메뉴막대 표시 허용을 바로잡고 아래의 실제 UI 검증을 진행했다.
- 최초 빌드의 실제 권한 허용·캘린더 선택과 일정 조회는 아래에서 확인했다. 최종 재빌드의 권한, 외부 서비스 변경의 동기화와 재로그인은 따로 확인한다.
- 초기에는 자동 로그인 항목을 가짜 backend로만 검증했다. 이후 실제 등록과 enabled 상태를 확인했으며 재로그인은 수행하지 않았다. 검증 명목으로 로그아웃하거나 재부팅하지 않았다.

## 추가 발견과 수정

- 승인 대기 상태의 자동 실행 등록 취소 경로가 없었다. 상태를 켜짐으로 속이지 않고 등록 취소 버튼을 추가했다.
- 여러날 종일 일정의 진행 상태를 표시하지 않았다. 종일 · 진행 중 표시와 회귀 테스트를 추가했다.
- 오늘 색이 시스템 강조색을 따라 바뀌었다. 고정 파랑으로 수정했다.
- 다음 자정 계산에도 Asuncion 01:00 전파 문제가 있었다. 다음날의 하루 시작으로 정규화했다.
- 제한 실행에서 부모만 종료하고 SIGTERM을 무시하는 손자 프로세스가 남을 수 있었다. 그룹 단위 정리를 추가했다. `python3 -B -m unittest discover -s scripts -p test_run.py`: 실제 프로세스 3개 시나리오 exit 0이며 전체 검증 명령에도 포함했다.
- 사용자 확인으로 팝오버 좌하단 표시와 외부 클릭 닫힘 실패가 드러났다. 화면 없는 기준점 표시를 차단하고 외부/앱 내부 클릭 및 앱 비활성화 닫기를 추가했다. 변경 후 실제 아이콘에서의 검증을 진행 중이다.

## 실제 연결 확인

정상 앱 번들 실행에서 일정 권한 허용 후 시스템의 Google 기본 캘린더를 선택했다. 2026-09-29에서 실제 일정 2개와 시간·제목 표시, 날짜 점 표시를 UI로 확인했다. 개인 제목과 계정 주소는 이 기록에 넣지 않는다. 이 시점은 이전 빌드의 확인이며, 아래의 최종 UI 확인과 재실행 기록에서 권한 복원·드래그 결과를 추가했다.

## 최종 UI 동작 확인

메뉴막대 표시를 허용한 뒤 실제 팝오버의 연결 화살표가 상단에 붙는 것을 캡처로 확인했다. 화면 없는 좌표에서는 열지 않는 검사도 테스트했다. 왼쪽 드래그로 9/28→10/28, 오른쪽 드래그로 9/28 복귀, 24pt 짧은 드래그에 월·선택일 불변을 실제 UI에서 확인했다. Escape 후 창 접근 timeout과 명시적 재열기 시 오늘 복귀를 확인했다. 자동화 도구는 닫힌 팝오버의 접근성 내용을 보관할 수 있어 텍스트 트리 존재만으로 열린 상태라고 판정하지 않는다.

Apple 캘린더에서 같은 Google 캘린더의 9/29 일정 개수·제목·시각이 앱의 이전 조회와 일치함을 읽기 전용으로 대조했다. 캘린더 원본에는 쓰지 않았다. 이 기록 뒤 동일 설치본의 재실행에서 권한과 선택 복원을 확인했다. 바깥 클릭은 최종 사용자 확인을 요청했다.

## 재실행과 자동 실행 확인

동일 설치본을 앱의 종료 버튼으로 종료한 뒤 다시 열어 캘린더 접근과 선택이 유지되고 정상 0건 상태로 돌아오는 것을 확인했다. Google 9/29 일정 2개와 9/17 종일 일정 1개의 표시를 최종 UI에서 읽었다. 2026년 8월의 6주 배치를 캡처하여 마지막 주와 일정 영역이 함께 보이는지 확인했다.

실제 설치본의 로그인 실행 스위치를 켠 뒤 시스템 조회 상태가 enabled로 바뀌는 것을 확인했다. 최초 상태 notFound를 실패 표시로 처리하면서 초기 등록을 건너뛰는 코드 경로를 발견하여 최초 실행은 enabled/승인 대기 이외 상태에서 등록을 시도하도록 고쳤다. 회귀 테스트 실패→통과를 확인했다. 실제 로그아웃/재로그인은 수행하지 않았다.

## 수정 위치

| 확인한 문제 | 현재 수정 위치 |
|---|---|
| 자정 건너뛰기 월 격자 | `Sources/CalendarCore/CalendarState.swift:23` |
| 빈 제목 괄호 | `Sources/CalendarCore/EventOccurrence.swift:42` |
| 앱 진입 main actor | `Sources/CalendarBar/main.swift:26` |
| 승인 대기 등록 취소 | `Sources/CalendarUI/CalendarPopover.swift:174` |
| 종일 연속 일정 구분 | `Sources/CalendarUI/CalendarModel.swift:56` |
| 오늘 고정 파랑 | `Sources/CalendarUI/CalendarPopover.swift:77` |
| 다음 자정 보정 | `Sources/MenuBar/StatusDate.swift:10` |
| 하위 프로세스 정리 | `scripts/run.py:38` |
| 화면 없는 팝오버 기준점 | `Sources/MenuBar/MenuBarController.swift:81` |
| 외부 클릭·비활성화 닫기 | `Sources/MenuBar/MenuBarController.swift:91` |
| 최초 notFound 상태 등록 | `Sources/MenuBar/LoginItemController.swift:78` |
