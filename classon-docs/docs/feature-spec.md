# Classon 기능명세서

> 기능 하나를 구현할 때 이 문서의 해당 ID 블록과 `erd.md`의 관련 테이블을 함께 본다.
> API는 초안이다. 경로·필드는 구현하면서 바꿀 수 있지만, **규칙**은 바꾸기 전에 팀과 합의한다.
> "미결정" 표시는 `planning.md` 8장의 가정을 따르되, 구현 전에 확인한다.

## 0. 공통 규칙

**API**
- 기본 경로: `/api/v1`
- 응답 형식: `{ "success": true, "data": ..., "error": null }` / 실패 시 `{ "success": false, "data": null, "error": { "code": "STUDENT_NOT_FOUND", "message": "..." } }`
- 목록은 페이지네이션: `?page=0&size=20&sort=createdAt,desc` → `{ content, page, size, totalElements }`
- 날짜: `yyyy-MM-dd`, 일시: ISO-8601 (`2026-11-06T10:29:00`), 시간대 Asia/Seoul

**권한 표기**
- `ADMIN`: 관리자만
- `TEACHER`: 강사 (관리자도 가능)
- `OWNER`: 해당 데이터를 만든 사람 (+ 관리자)
- `CLASS_TEACHER`: 학생이 속한 반의 담당 강사 (+ 관리자)

**비동기 작업**
- AI 생성·채점·분석은 요청 즉시 `202 Accepted`와 대상 id를 돌려주고, 백그라운드에서 처리한다.
- 진행 상황은 상태 조회 API(폴링)로 확인한다.

**마일스톤**: M0 공통 기반 · M1 계정 · M2 반·학생 · M3 원본·AI 생성 · M4 자료찾기·수정본 · M5 단어시험 · M6 모의고사·분석 · M7 리포트

---

## 1. 공통 기반 (common) — M0

### COM-01 공통 응답·예외 처리
- `ApiResponse<T>`로 모든 응답을 감싼다.
- `BusinessException(ErrorCode)` + `@RestControllerAdvice` 전역 핸들러.
- 검증 실패(`MethodArgumentNotValidException`)는 `INVALID_INPUT`과 필드별 메시지로 응답.
- 없는 주소는 `NOT_FOUND`, 권한 없음은 `FORBIDDEN`, 미로그인은 `UNAUTHORIZED`.

### COM-02 BaseEntity
- `created_at`, `updated_at` 자동 기록 (JPA Auditing). 모든 엔티티가 상속.

### COM-03 파일 저장 (`common.file`)
- `FileStorage` 인터페이스: `save(파일, 경로 접두어) → file_key`, `load(file_key)`, `delete(file_key)`
- 구현체: `LocalFileStorage` (업로드 폴더). 나중에 `S3FileStorage` 추가 가능하게.
- 저장 파일명은 UUID로 바꾸고, 원래 이름은 필요한 테이블에 따로 저장.
- 다운로드는 항상 서버 API를 거치며 권한을 확인한다.

### COM-04 AI 클라이언트 (`common.ai`) — M3에서 구현
- `AiClient` 인터페이스: `send(AiRequest) → AiResponse` (텍스트, 이미지 입력 지원)
- 구현체: `ClaudeAiClient` (운영·로컬), `FakeAiClient` (테스트, 고정 응답)
- 모델 이름은 `application.yml`에서 설정 (`classon.ai.model.generate`, `classon.ai.model.grade` 등)
- 호출마다 `ai_usage_logs`에 사용자, 목적, 토큰 수, 성공 여부 기록. 프롬프트·응답 원문은 저장 금지.
- 학생 식별 정보 전송 금지 (CLAUDE.md AI 규칙).

### COM-05 API 문서
- springdoc(Swagger UI). 프론트는 Swagger를 기준으로 화면을 만든다.

---

## 2. 계정·로그인 (user) — M1

> 미결정: 로그인 방식(세션 / JWT). 아래는 JWT 기준 초안.
> 가정: 회원가입 없음, 관리자가 강사 계정 발급, 단일 학원.

### USR-01 로그인
- 권한: 누구나
- `POST /api/v1/auth/login` `{ loginId, password }` → `{ accessToken, refreshToken, user: { id, name, role } }`
- 규칙
  - 아이디·비밀번호가 틀리면 같은 메시지(`LOGIN_FAILED`)로 응답 (어느 쪽이 틀렸는지 알려 주지 않음)
  - `status = INACTIVE`면 로그인 거부 (`INACTIVE_ACCOUNT`)

### USR-02 토큰 재발급 / 로그아웃
- `POST /api/v1/auth/refresh`, `POST /api/v1/auth/logout`

### USR-03 내 정보 조회
- 권한: TEACHER
- `GET /api/v1/users/me` → `{ id, loginId, name, role }`

### USR-04 비밀번호 변경
- 권한: 본인
- `PATCH /api/v1/users/me/password` `{ currentPassword, newPassword }`

### USR-05 강사 계정 발급
- 권한: ADMIN
- `POST /api/v1/admin/users` `{ loginId, name, initialPassword, role }`
- 규칙: `login_id` 중복 금지 (`DUPLICATE_LOGIN_ID`). 비밀번호는 BCrypt로 저장.

### USR-06 계정 목록·수정
- 권한: ADMIN
- `GET /api/v1/admin/users?status=ACTIVE`, `PATCH /api/v1/admin/users/{id}` `{ name, role }`

### USR-07 계정 비활성화·활성화
- 권한: ADMIN
- `PATCH /api/v1/admin/users/{id}/status` `{ status: "INACTIVE" }`
- 규칙: 삭제하지 않는다. 비활성 강사가 쓴 자료·수정본·메모는 그대로 유지된다.
  비활성 강사가 담당하던 반은 관리자가 다른 강사로 바꾼다 (자동 변경하지 않음).
- 테이블: users

---

## 3. 반·학생·메모 (classroom, student) — M2

### CLS-01 반 생성
- 권한: ADMIN
- `POST /api/v1/classes` `{ name, grade?, teacherId }`
- 규칙: 활성 반 중에서 이름 중복 금지 (서비스에서 검사). `teacherId`는 ACTIVE 강사만.

### CLS-02 반 목록
- 권한: TEACHER
- `GET /api/v1/classes?mine=true&active=true` → 반 이름, 학년, 담당 강사 이름, 학생 수

### CLS-03 반 수정 (이름, 담당 강사 변경)
- 권한: ADMIN
- `PATCH /api/v1/classes/{id}`
- 규칙: 담당 강사를 바꾸면 그 반 학생의 수정 권한이 새 강사에게 넘어간다. 기존 메모는 유지(작성자 그대로).

### CLS-04 반 비활성화
- 권한: ADMIN
- `PATCH /api/v1/classes/{id}/active` `{ active: false }`
- 규칙: 삭제하지 않는다. 소속 학생이 있으면 먼저 다른 반으로 옮기거나 미배정으로 바꾸라고 안내.

### STU-01 학생 등록
- 권한: ADMIN, 또는 등록할 반의 담당 강사
- `POST /api/v1/students` `{ name, schoolName, grade, phone?, parentPhone?, classId? }`
- 규칙: `classId` 없이 등록하면 반 미배정 학생.

### STU-02 학생 검색
- 권한: TEACHER (모든 강사)
- `GET /api/v1/students?keyword=&classId=&grade=&page=` → id, 이름, 학교, 학년, 반 이름, 담당 강사
- 규칙: `deleted_at IS NULL`인 학생만. 이름 부분 검색.

### STU-03 학생 상세
- 권한: TEACHER (모든 강사)
- `GET /api/v1/students/{id}` → 기본 정보, 반, 담당 강사, `editable`(로그인 강사가 수정 가능한지)
- 성적·메모·분석은 각 도메인 API로 따로 조회 (WT-09, MOCK-05, MOCK-06, STU-07, ANA-02).

### STU-04 학생 수정 (반 이동 포함)
- 권한: CLASS_TEACHER
- `PATCH /api/v1/students/{id}`
- 규칙: 반을 옮기면 `class_id`만 바뀐다. 배정 이력은 남기지 않는다. 성적은 학생에 연결돼 그대로.

### STU-05 학생 삭제 (soft delete)
- 권한: ADMIN
- `DELETE /api/v1/students/{id}` → `deleted_at` 기록
- 규칙: 실제 DELETE 금지. 성적·리포트는 유지. 목록·검색에서 사라진다.

### STU-06 메모 작성·수정·삭제
- 권한: 작성 = CLASS_TEACHER / 수정·삭제 = 메모 작성자(OWNER)
- `POST /api/v1/students/{id}/memos` `{ content }`, `PATCH|DELETE /api/v1/memos/{memoId}`
- 규칙: 입력 화면에 "실명·연락처를 적지 마세요" 안내. `author_id`는 로그인 사용자.

### STU-07 메모 목록
- 권한: TEACHER
- `GET /api/v1/students/{id}/memos?page=` → 최신순, 작성자 이름 포함
- 테이블: classes, students, student_memos

---

## 4. 원본 지문·AI 자료 생성 (material) — M3

### MAT-01 원본 업로드
- 권한: ADMIN(공식) / TEACHER(개인)
- `POST /api/v1/passages` (multipart) `{ file?, passageText?, title, category, grade?, examYear?, examMonth?, questionNo?, publisher?, unitLabel?, extraPrompt? }`
- 규칙
  - `origin`은 로그인 권한으로 자동 결정: ADMIN → OFFICIAL, TEACHER → PERSONAL
  - 파일을 올리면 서버가 텍스트를 추출해 `passage_text`에 저장, 파일은 `file_key`로 보관
  - `category`별 필수값 검사: MOCK_EXAM → examYear, examMonth / TEXTBOOK → publisher
  - 개인 자료 업로드 화면에 "이용 권한이 있는 자료만 올리세요" 안내
  - 저장 직후 MAT-02 생성을 시작하고 `202`와 `passageId` 반환
- 테이블: source_passages

### MAT-02 AI 자료 3종 생성 (비동기)
- 트리거: MAT-01 직후
- 흐름
  1. `source_passages.status = GENERATING`, `materials` 3행(VOCAB, ANALYSIS, LESSON)을 `gen_status = GENERATING`으로 생성
  2. 자료별로 AI 호출 (`passage_text` + `extra_prompt` + 자료 종류별 시스템 프롬프트)
  3. 성공한 자료는 `content_json` 저장 + `SUCCESS`, 실패하면 `FAILED`
  4. 3개가 모두 끝나면 원본 `status = REVIEW` (전부 실패면 `FAILED`)
- 규칙
  - VOCAB의 `content_json`에는 단어 목록(단어, 지문 속 뜻, 품사, 지문 원문 예문, 순서)
  - 교과서 단원 구조 차이는 프롬프트에서 LLM이 판단
  - 실패 이유는 서버 로그에만 남김
- 테이블: source_passages, materials, ai_usage_logs

### MAT-03 생성 상태 조회
- 권한: OWNER
- `GET /api/v1/passages/{id}/status` → `{ status, materials: [{ type, genStatus }] }`

### MAT-04 미리보기
- 권한: OWNER
- `GET /api/v1/passages/{id}/preview` → 원본 정보 + 자료 3종의 `content_json`
- 규칙: `REVIEW` 상태에서만

### MAT-05 간단 수정
- 권한: OWNER
- `PATCH /api/v1/materials/{materialId}/content` `{ contentJson }`
- 규칙: 원본 `REVIEW` 상태에서만. 확정 후 수정 불가 (`ALREADY_CONFIRMED`).

### MAT-06 자료별 재생성
- 권한: OWNER
- `POST /api/v1/materials/{materialId}/regenerate` `{ extraPrompt? }` → `202`
- 규칙
  - 원본 `REVIEW` 상태에서만
  - 새 행을 만들지 않고 같은 행을 덮어씀. `regen_count + 1`
  - 횟수 제한은 보류 (개발 완료 후 결정)

### MAT-07 일괄 확정
- 권한: OWNER
- `POST /api/v1/passages/{id}/confirm`
- 규칙
  - 3종 모두 `SUCCESS`가 아니면 거부 (`MATERIALS_NOT_READY`)
  - 확정 시 한 트랜잭션에서:
    1. VOCAB의 `content_json`을 풀어서 `vocab_entries`에 저장
    2. 3종 각각 docx 생성 → `materials.file_key`
    3. 원본 `status = CONFIRMED`, `confirmed_by`, `confirmed_at`
  - docx 생성이 실패하면 확정 전체를 롤백
  - 개인 자료(PERSONAL)면 응답에 `askShare: true` → 프론트가 "공유하시겠습니까?" 모달 (SRCH-04)
- 테이블: source_passages, materials, vocab_entries

### MAT-08 원본 삭제
- 권한: ADMIN(공식, 개인 모두) / OWNER(본인 개인 자료)
- `GET /api/v1/passages/{id}/delete-impact` → `{ materialCount, revisionCount }`
- `DELETE /api/v1/passages/{id}`
- 규칙
  - 삭제 전 영향받는 수정본 수를 보여 주고 확인을 받는다 (프론트)
  - DB CASCADE로 materials → vocab_entries, material_revisions 삭제
  - 저장소의 파일(원본, 자료 docx, 수정본 docx)도 함께 삭제
  - 이 원본을 `prev_version_id`로 가리키던 새 버전은 SET NULL
  - 이미 치른 단어시험 점수에는 영향 없음

### MAT-09 새 버전 원본 업로드
- 권한: ADMIN
- `POST /api/v1/passages/{id}/new-version` (MAT-01과 같은 입력)
- 규칙: 새 원본의 `prev_version_id = {id}`, 제목 옆에 "(수정본)" 표시. 기존 원본·자료·수정본은 그대로.

---

## 5. 자료찾기·수정본 (material) — M4

### SRCH-01 자료찾기 검색
- 권한: TEACHER
- `GET /api/v1/library?tab=OFFICIAL|PERSONAL_SHARED&category=&grade=&examYear=&publisher=&keyword=&page=`
- 규칙
  - OFFICIAL 탭: `origin = OFFICIAL` 이고 `status = CONFIRMED`인 원본
  - PERSONAL_SHARED 탭(개인자료 공유): `origin = PERSONAL`, `CONFIRMED`, 자료 `is_shared = true`
  - 결과는 원본 단위로 묶어서 자료 3종을 함께 보여 줌
  - 정렬 기본: 확정일 최신순 (미결정: 검색 조건·정렬 기준 확정 필요)

### SRCH-02 자료 상세
- 권한: TEACHER
- `GET /api/v1/passages/{id}` → 원본 정보, 자료 3종, 새 버전 존재 여부, 수정본 목록(REV-02)

### SRCH-03 자료 다운로드
- 권한: TEACHER (공개된 자료) / OWNER (비공개 개인 자료)
- `GET /api/v1/materials/{materialId}/download` → docx

### SRCH-04 개인 자료 공유·해제
- 권한: OWNER
- `PATCH /api/v1/materials/{materialId}/share` `{ shared: true|false }`
- 규칙: 해제하면 다른 강사의 목록·다운로드 즉시 차단. 원본이 OFFICIAL이면 거부 (공식 자료는 항상 공개).

### REV-01 수정본 업로드
- 권한: TEACHER
- `POST /api/v1/materials/{materialId}/revisions` (multipart) `{ file, subtitle, intent? }`
- 규칙
  - 대상 자료의 원본이 `OFFICIAL` 이고 `CONFIRMED`여야 함 (`REVISION_NOT_ALLOWED`)
  - docx만 허용: 확장자 + MIME 타입 검사 (`INVALID_FILE_TYPE`)
  - `seq_no` = 같은 자료·같은 강사의 MAX + 1. UK 충돌 시 재시도
  - 표시 파일명: `{기존파일명}({subtitle})_{강사이름}강사Ver{seq_no}.docx`
  - 기본 비공개 (`is_shared = false`)
- 테이블: material_revisions

### REV-02 수정본 목록
- 권한: TEACHER
- `GET /api/v1/materials/{materialId}/revisions`
- 규칙: 공유된 수정본 + 내가 올린 비공개 수정본만. 강사 이름 + Ver 순번, 소제목 표시.

### REV-03 수정본 다운로드
- 권한: 공유된 수정본은 TEACHER / 비공개는 OWNER
- `GET /api/v1/revisions/{id}/download` → 표시 파일명으로 내려줌

### REV-04 수정본 공유·해제
- 권한: OWNER (작성자만, 관리자 아님)
- `PATCH /api/v1/revisions/{id}/share` `{ shared }`

### REV-05 수정본 정보 수정
- 권한: OWNER
- `PATCH /api/v1/revisions/{id}` `{ subtitle, intent }`
- 규칙: 파일 교체는 안 됨. 파일을 바꾸려면 새 수정본으로 업로드 (새 Ver).

### REV-06 수정본 삭제
- 권한: OWNER, ADMIN
- `DELETE /api/v1/revisions/{id}`
- 규칙: 지운 Ver 번호는 다시 쓰지 않는다. 저장소 파일도 삭제.

---

## 6. 단어시험 (wordtest) — M5

> 시험지와 정답지는 저장하지 않는다. 점수는 `word_test_results`에만 저장한다.

### WT-01 출제용 단어장 목록
- 권한: TEACHER
- `GET /api/v1/word-tests/vocab-sources?scope=OFFICIAL|MY_PERSONAL&keyword=`
- 규칙
  - OFFICIAL: 확정된 공식 원본의 VOCAB 자료
  - MY_PERSONAL ("기타 자료 추가"): 내가 만든 개인 자료의 VOCAB (확정된 것)
  - 수정본은 제외 (미결정: 수정본 포함 여부)

### WT-02 시험지 생성·다운로드
- 권한: TEACHER
- `POST /api/v1/word-tests/paper` `{ materialIds: [..], questionCount, questionType?, classId?, title }` → PDF 파일 응답
- 규칙
  - 고른 단어장들의 `vocab_entries`를 합쳐서 `questionCount`개를 무작위로 뽑음
  - 단어가 부족하면 있는 만큼 출제하고 응답 헤더로 알림
  - PDF만 내려주고 서버에 저장하지 않음
  - (선택) 학생별 페이지 + QR(batch_key, student_id)로 스캔 자동 매칭
  - 미결정: 문제 유형(영→한 / 한→영 / 혼합). 기본 영→한

### WT-03 스캔본 업로드 (채점 묶음 생성)
- 권한: TEACHER
- `POST /api/v1/word-tests/batches` (multipart) `{ title, testDate, total, classId?, files: [...], studentIds: [...] }`
- 규칙
  - 서버가 `batch_key`(UUID)를 만들고, 파일 1개당 `word_test_results` 1행 생성 (`status = AI_GRADING`)
  - 시험명·날짜·문항 수·반은 묶음 전체에 같은 값으로 복사
  - 파일 1개 = 학생 1명 1장. 학생 매칭은 업로드 화면에서 선택 (QR 방식이면 자동)
  - 같은 묶음에 같은 학생 중복 금지 (UK). 다시 올리면 기존 행을 덮어씀
  - 업로드 즉시 `202`와 `batchKey` 반환, WT-04 시작

### WT-04 AI 1차 채점 (비동기)
- 흐름
  1. 스캔 이미지를 AI에 전달 (학생 이름이 보이는 영역은 가능하면 가린다)
  2. AI가 문항별로 인쇄된 문제와 학생 답을 읽고, 단어의 뜻을 판단해 정오를 매김
  3. 판독이 불확실하면 정오를 매기지 않고 `unsure = true`
  4. 결과를 `ai_grading` JSON에 저장, `score` = 맞은 수, `status = NEEDS_REVIEW`
- `ai_grading` 형식: `[{ "no": 1, "question": "abandon", "read": "포기하다", "correct": true, "unsure": false }, ...]`
- 테이블: word_test_results, ai_usage_logs

### WT-05 채점 묶음 목록·진행 현황
- 권한: TEACHER (내가 올린 묶음)
- `GET /api/v1/word-tests/batches?page=` → 시험명, 날짜, 반, 전체 수, AI 채점 중 / 확인 대기 / 확정 수, 평균(확정분)

### WT-06 2차 채점 화면 조회
- 권한: OWNER (묶음을 올린 강사) 또는 CLASS_TEACHER
- `GET /api/v1/word-tests/batches/{batchKey}/results` → 학생별 점수, 상태, `ai_grading`, 스캔본 보기 링크
- 규칙: `unsure = true` 문항을 먼저 눈에 띄게 표시

### WT-07 문항 정오 수정
- 권한: WT-06과 같음
- `PATCH /api/v1/word-tests/results/{id}/items/{no}` `{ correct: true|false }`
- 규칙: `ai_grading`의 해당 문항을 바꾸고 `score`를 문항 결과로 **다시 계산**. 점수 직접 입력 API는 만들지 않는다.
  `CONFIRMED` 이후에도 수정 가능하게 할지는 미결정 (기본: 확정 후 수정 불가).

### WT-08 채점 확정
- 권한: WT-06과 같음
- `POST /api/v1/word-tests/results/{id}/confirm`, 일괄: `POST /api/v1/word-tests/batches/{batchKey}/confirm`
- 규칙
  - `unsure = true` 문항이 남아 있으면 확정 거부 (`UNSURE_ITEMS_REMAIN`)
  - `status = CONFIRMED`, `confirmed_by`, `confirmed_at`. 이 순간부터 학생 성적에 반영

### WT-09 학생별 단어시험 점수 조회 (그래프)
- 권한: TEACHER
- `GET /api/v1/students/{id}/word-test-scores?from=&to=` → `[{ testDate, title, score, total }]`
- 규칙: `CONFIRMED`만, `test_date` 오름차순

### WT-10 스캔본 파기 (배치)
- 매일 1회: 확정 후 보관 기간이 지난 스캔본 파일 삭제, `scan_file_key = NULL`, `scan_purged_at` 기록
- 미결정: 보관 기간

---

## 7. 모의고사 (mockexam) — M6

### MOCK-01 문항 유형 기준 정보
- 권한: ADMIN
- `GET|PUT /api/v1/admin/question-types`, `GET|PUT /api/v1/admin/question-type-map`
- 규칙: 1~45번 각각 유형 하나. 초기 데이터는 SQL로 넣는다 (2019년 이후 기준). 예외 처리는 미결정.

### MOCK-02 모의고사 회차
- 권한: TEACHER
- `GET /api/v1/mock-exams?year=&grade=`, `POST /api/v1/mock-exams` `{ examYear, examMonth, grade, title }`
- 규칙: (연도, 월, 학년) 중복 금지. 성적 입력 시 회차가 없으면 같이 만들어도 됨.

### MOCK-03 성적 입력 (모달)
- 권한: CLASS_TEACHER
- `POST /api/v1/students/{id}/mock-results` `{ mockExamId, rawScore, gradeLevel, wrongQuestionNos: [3, 21, 34] }`
- 규칙
  - 같은 학생·같은 회차 중복 금지 (UK). 이미 있으면 수정(MOCK-04)으로 안내
  - 틀린 번호만 저장, 없는 번호는 정답으로 간주. 번호는 1~45
  - 미결정: 미응시 문항 처리 (기본: 틀림과 구분하지 않음)
- 테이블: mock_exams, mock_exam_results, mock_exam_wrong_answers

### MOCK-04 성적 수정·삭제
- 권한: CLASS_TEACHER
- `PUT|DELETE /api/v1/mock-results/{id}` (틀린 번호 목록은 통째로 교체)

### MOCK-05 학생별 모의고사 추이
- 권한: TEACHER
- `GET /api/v1/students/{id}/mock-results` → `[{ examYear, examMonth, title, rawScore, gradeLevel }]` 시험 순

### MOCK-06 유형별 정답률
- 권한: TEACHER
- `GET /api/v1/students/{id}/mock-analysis` → `[{ type, total, wrong, correctRate }]`, 취약 유형 목록
- 규칙
  - 모의고사 결과가 **2회 미만**이면 `{ available: false, reason: "NOT_ENOUGH_DATA" }`
  - 정답률 = (응시 횟수 × 해당 유형 문항 수 − 오답 수) / (응시 횟수 × 해당 유형 문항 수)
  - 취약 유형 판정 기준(예: 정답률 하위 3개 / 60% 미만)은 미결정, 설정값으로 둔다

---

## 8. 학습 분석 (analysis) — M6

### ANA-01 AI 분석 요청
- 권한: CLASS_TEACHER
- `POST /api/v1/students/{id}/analyses` `{ periodStart, periodEnd }` → `202`, `analysisId`
- 흐름
  1. 기간 안의 확정 단어시험 점수, 모의고사 성적·유형별 정답률, 강사 메모를 모음
  2. 학생 이름·연락처·학교명 제외, 메모는 이름·전화번호 마스킹
  3. AI 호출 → `ai_result` 저장, `status = AI_DRAFT`
- 규칙: 모의고사 2회 미만이면 유형 분석 부분은 빼고 요청

### ANA-02 분석 결과 조회
- 권한: TEACHER
- `GET /api/v1/students/{id}/analyses`, `GET /api/v1/analyses/{id}` → `ai_result`, `teacher_edited`, 상태

### ANA-03 강사 검수
- 권한: CLASS_TEACHER
- `PUT /api/v1/analyses/{id}/review` `{ teacherEdited }` → `status = REVIEWED`, `reviewed_at`
- 규칙: AI 원문(`ai_result`)은 바꾸지 않고, 수정본은 `teacher_edited`에 저장
- 테이블: student_analyses, ai_usage_logs

---

## 9. 학부모 리포트 (report) — M7

### RPT-01 리포트 생성
- 권한: CLASS_TEACHER
- `POST /api/v1/students/{id}/reports` `{ periodStart, periodEnd, analysisId?, format: "DOCX"|"PDF" }`
- 규칙
  - `analysisId`를 주면 그 분석이 `REVIEWED`여야 함 (`ANALYSIS_NOT_REVIEWED`)
  - 기간 안의 확정 성적 + 검수된 분석을 `content_snapshot`에 복사해서 저장
  - 파일 생성 → `file_key`. docx는 강사가 내려받아 직접 수정 가능
  - 불필요한 개인정보는 넣지 않음 (학생 이름·학년·반 정도)
- 테이블: parent_reports

### RPT-02 리포트 목록
- 권한: TEACHER
- `GET /api/v1/students/{id}/reports`

### RPT-03 리포트 다운로드
- 권한: TEACHER
- `GET /api/v1/reports/{id}/download`
- 규칙: 과거 리포트는 전부 보존. 성적이 나중에 바뀌어도 `content_snapshot`은 그대로.

---

## 10. 권한 요약

| 기능 | 관리자 | 담당 반 강사 | 다른 강사 | 작성자 |
|---|---|---|---|---|
| 강사 계정 발급·비활성화 | O | | | |
| 반 생성·수정·비활성화 | O | | | |
| 학생 검색·상세 조회 | O | O | O | |
| 학생 등록·수정 | O | O | | |
| 학생 삭제 (soft) | O | | | |
| 메모 작성 | O | O | | |
| 메모 수정·삭제 | | | | O |
| 공식 원본 업로드·확정·삭제 | O | | | |
| 개인 원본 업로드·확정 | | | | O (강사) |
| 개인 원본 삭제 | O | | | O |
| 자료찾기 조회·다운로드 | O | O | O | |
| 수정본 업로드 | | O | O | |
| 수정본 공유·정보 수정 | | | | O |
| 수정본 삭제 | O | | | O |
| 단어시험지 생성 | O | O | O | |
| 채점 묶음 업로드 | O | O | O | |
| 2차 채점·확정 | O | O | | O (묶음 업로드한 강사) |
| 모의고사 성적 입력·수정 | O | O | | |
| 성적·분석·리포트 조회 | O | O | O | |
| AI 분석 요청·검수 | O | O | | |
| 리포트 생성 | O | O | | |
| 문항 유형 기준 정보 | O | | | |
