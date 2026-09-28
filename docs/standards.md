# 변경과 검증 기준

Swift Package의 모듈 경계를 지킨다. CalendarCore는 Foundation 계산만, CalendarAccess는 CalendarCore와 시스템 일정 API, MenuBar는 메뉴막대와 로그인 항목, CalendarUI는 앞 세 모듈, CalendarBar는 앱 진입만 소유한다. Core에 UI나 EventKit 객체를 넣지 않는다.

일정 조회 API는 읽기만 노출한다. EventKit 객체를 actor 밖에 전달하지 않고 값으로 변환한다. UI 게시 상태는 main actor에서 변경하며 오래된 비동기 응답을 현재 결과로 채택하지 않는다. 새 외부 의존성은 플랫폼 기본 기능으로 해결할 수 없는 근거가 있을 때만 도입한다.

`python3 scripts/verify.py`가 전체 테스트와 release 앱 빌드·서명 검증을 실행한다. 코드 변경 후 이 명령의 exit 0을 확인한다. 날짜/권한/비동기 경계 변경은 실제 경계를 검증하는 테스트를 포함한다. 화면 동작 변경은 실제 앱에서 확인하고 모의 데이터 통과를 실제 계정 연동 성공으로 보고하지 않는다.

프로세스는 `scripts/run.py` 등 제한 시간과 종료 처리를 갖춘 실행으로 검증한다. 로그아웃·재부팅을 검증 명목으로 임의 수행하지 않는다. push·공개 배포는 사용자 승인 없이 하지 않는다. 작업 전 Git 변경을 확인하고 다른 작업자의 파일을 되돌리지 않는다.
