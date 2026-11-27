# CLAUDE.md

북메이트(Bookmate): 독서 소모임 웹 앱(2023년 팀 프로젝트)을 단계(Phase)별로 리팩토링하는 중이다. Spring Boot 앱은 `Soso/`에 있고, 루트에는 `docker-compose.yml`, `.env.example`, CI, `docs/refactoring/`이 있다. 공통 지침은 전역 `~/.claude/CLAUDE.md`에 있다.

## 지켜야 할 것

- **보안, 스키마, 플랫폼 코드를 바꾸기 전에 `docs/refactoring/phase*.md`를 먼저 읽는다.** 구조의 이유, 알려진 레거시 버그, 미룬 일(Phase 2: 서비스 계층 정리와 레거시 세션 브리지 제거, Phase 3-2: Boot 4.1)이 있다. 이 문서에 있는 내용은 코드를 다시 훑어 확인하지 않는다.
- 저장소는 **public**이다. 시크릿은 환경변수로만 받는다(`.env.example`).
- `Soso_Admin/`은 사용자가 로컬에서 작업 중이다. 요청 없이 건드리거나 커밋하지 않는다.
- 문서와 커밋 메시지는 한국어로 쓰고, 커밋 제목은 `Phase N-M: ...` 또는 `fix: ...` 형식을 따른다.
- **master push는 곧 운영 배포다**(`.github/workflows/deplow.yml`, CI는 `-DskipTests`). 사용자 확인 없이 push 하지 않고, push 전에 전체 테스트를 통과시킨다.
- 운영 서버 확인이 필요하면 `~/app/app.log` 일부, nginx 설정 등 필요한 부분만 사용자에게 붙여 달라고 한다.

## 명령어 (`Soso/`에서, Windows는 `mvnw.cmd`)

```bash
docker compose up -d                                        # (루트) 로컬 Oracle XE 1521, 최초 기동 1~2분
./mvnw spring-boot:run -Dspring-boot.run.profiles=local     # http://localhost:9000
./mvnw test -Dtest=LoginTest[#method]                       # Docker 필요(Testcontainers)
./mvnw clean package -DskipTests                            # target/Soso-*.war (CI와 동일)
```

Java 21, Spring Boot 3.5.x. `local` 프로필은 DB 계정이 없으면 `bookmate/bookmate`를 쓰고, 업로드 폴더는 `FILE_LOCATION`으로 바꿀 수 있다. Maven 출력은 `Select-String 'Tests run:|FAIL|BUILD'`로 필터한다.

## 구조

- Spring MVC + **JSP**(`src/main/webapp/WEB-INF/views`) + XML 매퍼 **MyBatis** + **Oracle**. 실행 가능한 WAR로 패키징한다.
- 기능별 패키지 `com.acorn.soso.<기능>`(`book`, `cafe`, `group`, `group_managing`, `support`, `users`, `users_info`): `controller → service(인터페이스+Impl) → dao(인터페이스+Impl) → SqlSession`. DAO는 `session.selectList("<namespace>.<id>", dto)`로 호출한다. 매퍼는 `src/main/resources/mapper/**/*.xml`이고, 하위 폴더를 새로 만들면 `mybatis.mapper-locations`에 추가한다.
- **스키마는 Flyway**(`db/migration`)가 관리하며 `V1__baseline_schema.sql`이 기준이다(`WEB-INF/table.sql`은 기준 아님). 변경은 새 `V{n}__*.sql`로만 하고, 적용된 마이그레이션은 고치지 않는다. 테이블 이름은 `*_TB`.
- **보안 규칙**(상세: `docs/refactoring/phase1-security.md`)
  - `SecurityConfig`는 기본이 로그인 필요다. 새 공개 화면은 `PUBLIC_PAGES`/`PUBLIC_ACTIONS`에 추가하고, 관리자 전용은 `ADMIN_ONLY`에 넣는다.
  - 상태를 바꾸는 엔드포인트는 모두 POST다. JSP에서는 `<a data-post href=...>` 또는 `postTo(url)`을 쓰고, 새 페이지 `<head>`에는 `resources/js/csrf.js`를 넣는다. `CsrfCookieFilter`나 `CsrfTokenRequestAttributeHandler`를 빼면 모든 POST가 403이 된다.
  - 레거시 코드는 `session.getAttribute("id")`로 로그인 사용자를 판단한다. 이 값은 Phase 2까지 `LoginSuccessHandler`가 세션에 넣고 유지한다. 로그인 후 이동 `url`은 `LegacySession.safeRedirectUrl`을 거친다.
  - 비밀번호 재확인은 `PwdAuthInterceptor`, 모임장 권한 검사는 아직 `GroupManagingController`에 있다.
  - 네이버 로그인(`naverLogin`, `/users/socialaccess`)은 Security와 연결되지 않은 보류 레거시다.
- 업로드 파일은 `${file.location}`에 저장한다. 프로필: `local`(docker), `real`(운영, nginx 뒤 127.0.0.1), `home`/`away`(레거시).

## 테스트

- 통합 테스트는 `support/OracleIntegrationTest`를 상속한다. JVM당 Oracle Testcontainer 하나에 Flyway를 적용하고, 각 테스트는 `@Transactional`로 롤백된다.
- MockMvc `csrf()`는 토큰 저장소를 바꿔 끼우므로, 실제 쿠키 왕복은 `CsrfCookieHttpTest`에서만 검증된다.
- 일부는 레거시 동작을 고정하는 특성 테스트다. 기대값을 "고치기" 전에 Phase 문서를 확인한다.
- **테스트 실행은 `test-runner` 에이전트에 맡긴다**(`.claude/agents/test-runner.md`, 전역의 서브에이전트 규칙의 예외).
  - 코드를 커밋한 직후: `local, <커밋 범위>`.
  - master push 직전: `local` + "push 직전"(전체 테스트).
  - push 직후: `deploy`(워크플로와 운영 스모크 `scripts/smoke.sh`).
  - 문서만 바꾼 커밋에는 호출하지 않는다. 테스트 매핑 표에 없는 패키지나 테스트를 새로 만들면 에이전트 파일의 표도 갱신한다.
