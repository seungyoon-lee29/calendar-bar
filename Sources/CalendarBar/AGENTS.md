# CalendarBar

앱 진입과 delegate 수명 연결을 담당한다.

시작은 main actor에서 하고 실행 중 delegate와 coordinator를 보관한다. 팝오버 닫힘으로 종료하지 않는다.

날짜 계산·EventKit 조회·화면 레이아웃은 이 모듈의 범위가 아니다.

정상 번들 실행과 --smoke --show를 구분한다. 진입점 변경 후 실제 실행 콜백과 메뉴막대를 확인한다.
