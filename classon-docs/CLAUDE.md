# Classon Backend

영어학원 강사용 AI 수업·시험 관리 플랫폼의 백엔드.
관리자가 올린 영어 지문으로 AI가 자료 3종을 만들고, 강사는 자료를 활용·수정·공유하며,
학생의 단어시험·모의고사 성적을 관리하고 학부모 리포트를 만든다.

## 반드시 먼저 읽을 문서

| 문서 | 내용 | 언제 읽나 |
|---|---|---|
| `docs/planning.md` | 기획 요약, 정책, 확정된 결정, 미결정 사항 | 기능의 "왜"가 궁금할 때 |
| `docs/feature-spec.md` | 기능명세서 (기능 ID, 규칙, API 초안, 관련 테이블) | 기능을 구현하기 전에 항상 |
| `docs/erd.md` | 테이블 17개의 컬럼, FK, ON DELETE, 제약 | 엔티티·쿼리를 만들기 전에 항상 |

문서와 다르게 구현해야 할 이유가 생기면 **코드를 고치기 전에 먼저 물어본다.**
문서에 "미결정"으로 표시된 항목은 임의로 정하지 말고 물어본다.

## 기술 스택

- Java 21, Spring Boot, Gradle (Groovy)
- Spring Web, Spring Data JPA, MySQL 8, Spring Security, Validation, Lombok
- 로컬 DB: `docker compose up -d` (MySQL 8, utf8mb4, Asia/Seoul)
- 외부 AI: Claude API (`common.ai` 모듈을 통해서만 호출)

## 패키지 구조

```
com.classon
├─ common        공통 응답, 예외·에러코드, BaseEntity, 보안 설정, ai, file
├─ user          계정, 로그인, 권한 (users)
├─ classroom     반 (classes)
├─ student       학생, 학생 메모 (students, student_memos)
├─ material      원본지문, 생성자료, 단어, 수정본 (source_passages, materials, vocab_entries, material_revisions)
├─ wordtest      단어시험 시험지 생성, 채점 (word_test_results)
├─ mockexam      모의고사, 문항 유형 (mock_exams, mock_exam_results, mock_exam_wrong_answers, question_types, question_type_map)
├─ analysis      학생 학습 분석 (student_analyses)
└─ report        학부모 리포트 (parent_reports)
```

각 도메인 안은 `controller / service / repository / domain / dto`로 나눈다.
다른 도메인의 Repository를 직접 쓰지 않고, 그 도메인의 Service(또는 조회용 인터페이스)를 통해 접근한다.

## 코딩 규칙

- 엔티티에 `@Setter` 금지. 상태 변경은 의미 있는 메서드로 한다 (`confirm()`, `share()`, `softDelete()`).
- 엔티티 생성은 정적 팩토리 메서드나 `@Builder`를 쓰고, 기본 생성자는 `protected`.
- enum은 항상 `@Enumerated(EnumType.STRING)`. DB 컬럼은 `VARCHAR(20)`.
- 연관관계는 기본 `LAZY`. 목록 조회에서 N+1이 생기면 fetch join이나 `@EntityGraph`로 푼다.
- `open-in-view: false`. 트랜잭션은 Service 계층에서 건다.
- Controller는 DTO만 주고받는다. 엔티티를 응답으로 그대로 반환하지 않는다.
- 요청 DTO는 Bean Validation(`@NotBlank`, `@Size` 등)으로 검증한다.
- 예외는 `common`의 `BusinessException` + `ErrorCode`로 던지고, 전역 핸들러가 공통 응답으로 바꾼다.
- 모든 엔티티는 `BaseEntity`(created_at, updated_at, JPA Auditing)를 상속한다.
- 새 기능에는 Service 단위 테스트를 같이 작성한다. 테스트에서 실제 AI를 호출하지 않는다 (`FakeAiClient` 사용).
- 비밀 값(DB 비밀번호, AI API 키)은 환경변수로만 읽는다. 코드·yml에 실제 값을 쓰지 않는다.

## 깨면 안 되는 도메인 규칙

### 데이터 삭제
- 학생은 **soft delete**만 한다 (`deleted_at`). 실제 DELETE 금지. 조회는 항상 `deleted_at IS NULL`.
- 사용자(강사·관리자)는 삭제하지 않고 `status = INACTIVE`. INACTIVE는 로그인 차단, 작성한 자료는 유지.
- 반은 삭제하지 않고 `is_active = false`.
- 원본지문 삭제 시 `materials → vocab_entries, material_revisions`가 DB CASCADE로 같이 삭제된다.
  삭제 전에 영향받는 수정본 수를 보여 주고 확인을 받는다.
- 과거 성적(단어시험, 모의고사)과 학부모 리포트는 전부 보존한다. 자료가 삭제돼도 성적은 남아야 한다.

### 자료
- 공식 자료 3종(VOCAB, ANALYSIS, LESSON)은 원본지문 하나당 종류별로 하나만 존재한다 (UK).
  재생성은 새 행을 만들지 않고 같은 행을 덮어쓴다.
- 재생성·간단 수정은 원본 `status = REVIEW`일 때만 가능하다.
- 확정은 원본 단위로 3종을 **한 번에** 한다. 3종이 모두 `gen_status = SUCCESS`여야 확정할 수 있다.
- 확정된(CONFIRMED) 공식 자료는 바꾸지 않는다. 새로 만들려면 새 버전 원본을 올린다 (`prev_version_id`).
- 강사에게 보이는 자료 = 원본 `CONFIRMED` 이고 (`origin = OFFICIAL` 또는 자료 `is_shared = true`).
- 수정본은 `origin = OFFICIAL` 이고 `CONFIRMED`인 자료에서만 만들 수 있다. 다른 수정본에서 파생 금지.
- 수정본 파일은 docx만 받는다. 확장자와 MIME 타입을 둘 다 검사한다.
- 수정본 순번(`seq_no`)은 같은 자료·같은 강사 기준 MAX+1. UK로 중복을 막는다.
- 수정본 수정·공유·삭제는 작성자만, 삭제는 관리자도 가능하다.

### 학생·성적
- 학생 검색·조회는 **모든 강사**가 할 수 있다.
  학생 정보 수정, 메모 작성, 성적 입력·확정은 **담당 반 강사**(`classes.teacher_id`)와 관리자만 할 수 있다.
- 권한 체크는 목록 API뿐 아니라 단건 조회·수정 API에도 넣는다.
- 단어시험 점수는 `status = CONFIRMED`일 때만 성적(그래프, 분석, 리포트)에 쓴다.
- 단어시험 점수는 사람이 직접 입력하지 않고, 문항별 정오(`ai_grading`)에서 다시 계산한다.
- 모의고사 취약 유형 분석은 모의고사 결과가 **2회 이상**일 때만 한다.
- 학부모 리포트에는 강사가 검수한(`status = REVIEWED`) 분석만 들어간다.

### AI
- AI 호출은 `common.ai`의 `AiClient` 인터페이스로만 한다. 호출마다 `ai_usage_logs`에 기록한다.
- AI에 학생 이름·연락처·학부모 연락처·학교명을 보내지 않는다. 내부 ID와 성적 데이터만 보낸다.
- 강사 메모를 AI에 보낼 때는 서버에서 해당 학생 이름과 전화번호 패턴을 마스킹한다.
- `ai_usage_logs`에는 프롬프트·응답 원문과 학생 식별 정보를 저장하지 않는다.
- AI 호출(자료 생성, 채점, 분석)은 비동기로 처리하고, 상태 컬럼으로 진행 상황을 표시한다.
- 실패 이유는 사용자에게 보여 주지 않고 서버 로그에만 남긴다.

### 파일
- 업로드 파일은 비공개 저장소에 두고 DB에는 `file_key`(경로)만 저장한다.
- 다운로드는 서버가 권한을 확인한 뒤 내려준다. 파일 URL을 공개하지 않는다.
- 개발·테스트·시연에는 실제 교재·기출 지문을 쓰지 않는다. 직접 쓴 샘플 지문만 쓴다.

## 명령어

```bash
docker compose up -d      # MySQL 실행
./gradlew bootRun         # 서버 실행
./gradlew test            # 테스트
./gradlew build           # 빌드 (테스트 포함)
```

## 작업 방식

- 큰 작업은 코드를 고치기 전에 계획(만들 파일, 바꿀 파일)을 먼저 보여 준다.
- 기능 하나 = 이슈 하나 = 브랜치 하나 (`feature/{이슈번호}-{기능}`), develop으로 PR.
- 커밋 메시지: `feat|fix|refactor|test|docs|chore: 내용 (#이슈번호)`
- 작업이 끝나면 `./gradlew test`를 돌려 통과를 확인한다.
- 설계(테이블, 규칙)가 바뀌면 `docs/erd.md`, `docs/feature-spec.md`도 같은 PR에서 고친다.
