# 빌드와 사용

검증 환경은 macOS 26.3.1 Apple Silicon, Xcode 설치, Swift 6.3.3이다. 패키지 최소 타깃은 macOS 14이며 구버전 실기 검증은 하지 않았다. 외부 패키지 설치는 필요 없다.

`python3 scripts/verify.py`는 테스트 후 release 빌드를 하고 `build/CalendarBar.app`에 실행 파일과 Info.plist를 묶어 로컬 ad-hoc 서명과 서명 검증을 수행한다. 유료 개발자 계정·공증·앱스토어 배포가 포함된 명령이 아니다. 일반 실행은 `open build/CalendarBar.app`이다. 로그인 등록은 앱 경로를 사용하므로 사용 중인 번들을 이동하면 로그인 실행 상태를 다시 확인한다.

macOS 인터넷 계정에서 Google 캘린더 동기화를 켜고 Apple 캘린더에 일정이 보이는지 확인한다. 앱에서 캘린더 연결을 누른 후 권한은 사용자가 허용한다. 표시할 캘린더를 고른다. 구글에서 수정한 일정은 macOS 동기화 이후 반영되며 즉시 반영을 보장하지 않는다.

자동 실행을 건드리지 않는 제한 실행은 `python3 scripts/run.py 120 build/CalendarBar.app/Contents/MacOS/CalendarBar --smoke --show`다. 이것은 로그인 실행 검증이 아니다. 테스트 종료 시 프로세스 종료를 확인한다. 실제 로그인 실행은 정상 모드 등록 상태와 사용자의 재로그인 확인을 따로 기록한다.
