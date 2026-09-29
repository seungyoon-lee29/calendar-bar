# 빌드와 사용

검증 환경은 macOS 26.3.1 Apple Silicon, Xcode 설치, Swift 6.3.3이다. 패키지 최소 타깃은 macOS 14이며 구버전 실기 검증은 하지 않았다. 외부 패키지 설치는 필요 없다.

`python3 scripts/verify.py`는 테스트 후 release 빌드를 하고 `build/CalendarBar.app`에 실행 파일과 Info.plist를 묶어 로컬 ad-hoc 서명과 서명 검증을 수행한다. 유료 개발자 계정·공증·앱스토어 배포가 포함된 명령이 아니다. 앱 아이콘은 `Resources/AppIcon.icns`를 번들에 복사해 쓴다. 디자인을 바꾸면 `swift scripts/make_icon.swift <임시>/AppIcon.iconset` 후 `iconutil -c icns <임시>/AppIcon.iconset -o Resources/AppIcon.icns`로 다시 만든다. 일반 실행은 `open build/CalendarBar.app`이다. 로그인 등록은 앱 경로를 사용하므로 사용 중인 번들을 이동하면 로그인 실행 상태를 다시 확인한다.

macOS 인터넷 계정에서 Google 캘린더 동기화를 켜고 Apple 캘린더에 일정이 보이는지 확인한다. 앱에서 캘린더 연결을 누른 후 권한은 사용자가 허용한다. 표시할 캘린더를 고른다. 구글에서 수정한 일정은 macOS 동기화 이후 반영되며 즉시 반영을 보장하지 않는다.

자동 실행을 건드리지 않는 제한 실행은 `python3 scripts/run.py 120 build/CalendarBar.app/Contents/MacOS/CalendarBar --smoke --show`다. 이것은 로그인 실행 검증이 아니다. 테스트 종료 시 프로세스 종료를 확인한다. 실제 로그인 실행은 정상 모드 등록 상태와 사용자의 재로그인 확인을 따로 기록한다.


## 합성 일정과 알림 실행

먼저 `python3 scripts/verify.py`로 정상 앱을 만든다. 기존 QA 앱이 실행 중이지 않고 `build/CalendarBarQA.app`이 없는 상태에서 `python3 scripts/prepare_qa.py`를 실행한다. 정상 번들을 복사하여 표시 이름 Calendar Bar QA, 식별자 `local.ian.CalendarBar.qa`로 구별하고 다시 ad-hoc 서명한다. 실제 사용 중인 Applications 설치본은 교체하지 않는다.

`python3 scripts/run_qa.py 300 build/CalendarBarQA.app --qa --qa-window --qa-notifications --qa-seed "$(python3 -c 'import time; print(int(time.time()) + 180)')"`는 LaunchServices로 별도 QA 앱을 열고 5분 뒤 해당 경로의 프로세스만 정리한다. 종료 후 `QA_PROCESS_ABSENT`를 확인한다. 메뉴 전용 창 접근이 안 되면 `--qa-window`가 동일 화면 컴포넌트를 일반 창으로 보여 준다. 이 창의 렌더 확인과 실제 메뉴 팝오버 확인은 구별한다.

QA의 알림 opt-in과 합성 기준 시각은 `~/Library/Application Support/local.ian.CalendarBar.qa/qa-launch.json`, 알림 설정은 같은 디렉터리의 `qa-reminders.json`에 저장된다. `.qa` 식별자는 인자 없이 다시 실행해도 이 설정과 합성 데이터를 사용하며 로그인 항목을 등록하지 않는다. 일반 `--smoke`는 실제 알림을 예약하지 않는다.

OS 검증은 QA의 알림 권한을 허용한 뒤 가까운 합성 일정에 두 시간을 저장하고 실제 예약 수를 확인한다. 트리거 전에 QA 앱을 완전히 종료하고 도착한 알림과 콜드 클릭 목적일을 확인한다. 두 번째는 앱이 다른 날짜를 표시하는 동안 클릭하여 웜 이동을 확인한다. 개인 일정 원본을 만들거나 바꾸지 않는다. 검사 후 QA 규칙을 끄고 앱 소유 예약·전달 상태를 확인하며 시험 전에 꺼져 있던 QA 알림 허용은 원상복구한다.

권한 요청이 오류로 끝나면 시스템 설정의 해당 QA 항목 등록·허용 상태를 읽어 확인한다. 다른 앱이나 전역 미러링/공유 알림 정책을 바꾸지 않는다. 코드 서명 검증 성공과 실제 알림 허용·전달 성공은 별개다. 다른 보조 실행 파일이 같은 bundle ID를 사용해도 원래 앱의 알림 조회 권한과 같다고 가정하지 않는다.

`.qa` 번들의 원래 CalendarBar 실행 파일에 `--qa-notification-report`를 주면 10초 이내에 자체 요청 식별자·예약/전달 시각·권한 수치를 JSON으로 출력하고 종료한다. 예: `python3 scripts/run.py 15 build/CalendarBarQA.app/Contents/MacOS/CalendarBar --qa-notification-report`. 별도 probe 실행 파일을 넣지 않는다. 일반 번들은 `qa_bundle_required`를 반환하며 이 경로는 일정 조회·설정 저장·알림 추가/취소를 실행하지 않는다. 제목·본문·userInfo는 출력하지 않는다.
