# 구현 주의점

America/Asuncion의 2023년 10월 1일은 00:00이 없고 01:00부터 시작한다. 월 시작에 날짜를 더하기만 하면 이후 셀과 조회 종료까지 01:00이 전파됐다. 각 날짜를 startOfDay로 정규화해야 표시 기간 밖 첫 한 시간을 조회하지 않는다. 회귀 테스트가 이 경우를 재현한다.

Swift Package 실행 파일의 최상위 코드는 현재 언어 설정에서 main actor로 간주되지 않는다. main-actor 앱 delegate 초기화는 명시적 main actor 문맥에 두며 NSApplication.run 동안 delegate를 보관한다.

현재 컴퓨터 사용 도구는 Finder 접근성 정보는 읽지만 이 메뉴막대 전용 앱의 bundle ID/앱 경로 접근에서 timeoutReached를 반환했다. 이 오류만으로 앱 미실행 또는 UI 정상이라고 판정할 수 없다. 시작 콜백과 프로세스 생존은 확인했지만 실제 상호작용은 별도 확인이 필요하다.
