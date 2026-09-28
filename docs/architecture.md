# 구성과 흐름

CalendarBar 진입점이 앱 수명과 CalendarUI의 조정자를 연결한다. CalendarUI는 CalendarCore의 날짜·일정 값을 화면으로 만들고 CalendarAccess에 표시 날짜 범위의 읽기를 요청한다. MenuBar는 내용 화면을 받아 AppKit 메뉴막대 팝오버에 담으며 화면 데이터에는 의존하지 않는다.

CalendarAccess는 EventKit 객체를 actor 안에 두고 불변 값만 UI로 전달한다. 사용자 선택 ID는 UserDefaults로 이어지고 일정 내용은 메모리에 머문다. 로그인 실행은 MenuBar에서 ServiceManagement에 연결한다. 구글 동기화는 macOS 계정 서비스가 담당하며 앱과 구글 서버 사이의 통신 경로는 없다.

아이콘 클릭 → 오늘 선택으로 초기화 → 표시 격자 기간 조회 → 권한/선택 확인 → 선택한 캘린더 발생분 읽기 → 최신 요청인지 확인 → 날짜별 점과 선택일 목록 표시 순서다. 앱의 조회는 시스템 저장소까지이며 구글 서버의 최신성은 이 경계 밖이다.
