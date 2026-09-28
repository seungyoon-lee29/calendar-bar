# 검증 기록

## 자동 검증

2026-09-28, macOS 26.3.1 / Apple Silicon / Swift 6.3.3 환경.

- `python3 scripts/verify.py`: exit 0. 내부 `swift test --jobs 2` 25개 테스트 통과, `python3 scripts/build.py` exit 0. release 앱 번들 빌드와 `codesign --verify --strict` 성공.
- 날짜 모델 8개, 메뉴막대 날짜·로그인 상태 8개, 일정 접근 6개, 화면 상태·제스처 계산 3개다.
- 구현 전 해당 타입이 없어 실패한 테스트(exit 1)를 확인한 뒤 구현했다. 가짜 backend는 사용자 일정과 로그인 항목을 변경하지 않는다.

## 발견 후 수정한 항목

- `Sources/CalendarCore/CalendarState.swift`의 격자 계산: America/Asuncion 2023-10을 조회하면 날짜에 01:00이 전파되어 마지막 날 다음 날짜의 첫 한 시간까지 조회했다. 각 날짜의 하루 시작 정규화로 수정했고 회귀 테스트의 실패→통과를 확인했다.
- `Sources/CalendarCore/EventOccurrence.swift`의 빈 제목: 괄호가 빠진 표시를 명세의 '(제목 없음)'으로 수정했고 테스트 통과를 확인했다.
- `Sources/CalendarBar/main.swift`의 초기화: Swift Package 진입점에서 main-actor delegate를 직접 초기화하면 통합 빌드 exit 1이었다. 명시적 main actor 문맥과 delegate 수명 유지로 수정 후 전체 검증 exit 0.

## 실제 실행과 한계

- 제한 시간을 둔 `CalendarBar --smoke --show` 프로세스 실행과 앱 시작 콜백을 확인했다. 스택 표본은 NSApplication 이벤트 루프 대기를 보였다. 이는 화면 정상 동작 증거가 아니다.
- 컴퓨터 사용 도구의 앱 bundle ID/절대 경로 접근은 `timeoutReached`로 실패했다. Finder 접근성 조회는 가능했지만 화면 캡처는 흰 화면이었다. 실제 달력 렌더·외부 클릭·Escape·드래그·6주 배치는 아직 검증하지 못했다.
- 실제 캘린더 권한 허용·선택 저장/재실행·구글 변경의 시스템 동기화 반영·실계정 반복/종일 일정 대조는 미검증이다.
- 자동 로그인 항목은 단위 테스트에서 가짜 backend로만 검증했다. 실제 등록·승인·재로그인은 미검증이다. 검증 명목으로 로그아웃하거나 재부팅하지 않았다.
