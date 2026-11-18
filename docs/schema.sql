-- =====================================================================
-- Classon DB 스키마 (PostgreSQL)
-- 출처: ERDCloud "Classon ERD 초안" + 다이어그램 노트
-- 상세 설명은 ERD.md 참고. 이 파일과 ERD.md는 항상 함께 수정한다.
--
-- 규칙
--  - PK: bigint GENERATED ALWAYS AS IDENTITY
--  - 시각: timestamptz / 날짜: date / JSON: jsonb
--  - 원래 enum이던 컬럼: varchar + CHECK (JPA @Enumerated(EnumType.STRING))
--  - "-- [확인 필요]" 표시는 ERD.md의 '미정·확인 필요' 항목과 연결됨
-- =====================================================================


-- ---------------------------------------------------------------------
-- 1. 사용자 · 반 · 학생
-- ---------------------------------------------------------------------

-- 유저 (강사/관리자 계정)
CREATE TABLE users (
    id             bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    login_id       varchar UNIQUE,
    password_hash  varchar,
    role           varchar CHECK (role IN ('ADMIN', 'TEACHER')),
    status         varchar CHECK (status IN ('ACTIVE', 'INACTIVE')),
    created_at     timestamptz
);

-- 반
CREATE TABLE classes (
    id          bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    name        varchar,
    teacher_id  bigint NOT NULL REFERENCES users (id),
    is_active   boolean
);

-- 학생 (soft delete: deleted_at IS NULL 인 행만 조회)
CREATE TABLE students (
    id            bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    class_id      bigint NOT NULL REFERENCES classes (id),
    name          varchar,
    school        varchar,
    grade         varchar,
    phone         varchar,
    parent_phone  varchar,
    status        varchar CHECK (status IN ('ACTIVE', 'INACTIVE')),
    deleted_at    timestamptz
);

-- 학생 메모
CREATE TABLE students_memo (
    id          bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    content     text,
    created_at  timestamptz,
    word_score  int,                                   -- [확인 필요] 단어시험 점수 저장 위치
    user_id     bigint NOT NULL REFERENCES users (id),
    student_id  bigint NOT NULL REFERENCES students (id)
);


-- ---------------------------------------------------------------------
-- 2. 자료 생성
-- ---------------------------------------------------------------------

-- 원본 지문
CREATE TABLE source_passages (
    id               bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    origin           varchar CHECK (origin IN ('OFFICIAL', 'PERSONAL')),
    uploader_id      bigint NOT NULL REFERENCES users (id),
    title            varchar,
    category         varchar,     -- 모의고사 / 교과서 / 기타
    grade            varchar,
    exam_year        smallint,
    exam_month       smallint,
    publisher        varchar,
    unit_label       varchar,
    passage_text     text,
    file_key         varchar,
    extra_prompt     text,
    status           varchar,     -- GENERATING / REVIEW / CONFIRMED / FAILED
    confirmed_by     bigint NOT NULL REFERENCES users (id),           -- [확인 필요] NOT NULL
    confirmed_at     timestamptz,
    prev_version_id  bigint NOT NULL REFERENCES source_passages (id), -- [확인 필요] NOT NULL (첫 버전은 NULL이라는 노트와 충돌)
    created_at       timestamptz,
    updated_at       timestamptz
);

-- 생성자료
CREATE TABLE materials (
    id                 bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    source_passage_id  bigint NOT NULL REFERENCES source_passages (id) ON DELETE CASCADE,
    created_by         bigint REFERENCES users (id),  -- [확인 필요] 최신 ERD의 컬럼명/NULL 여부로 맞출 것
    material_type      varchar,   -- vocab / analysis / lesson
    gen_status         varchar,   -- generating / success / failed
    content_json       jsonb,
    file_key           varchar,
    regen_count        int DEFAULT 0,
    is_shared          boolean DEFAULT false,
    shared_at          timestamptz,
    created_at         timestamptz,
    updated_at         timestamptz
);

-- 단어 (단어장 생성자료의 단어 목록)
CREATE TABLE vocab_entries (
    id              bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    material_id     bigint NOT NULL REFERENCES materials (id) ON DELETE CASCADE,
    word            varchar,
    meaning         varchar,
    part_of_speech  varchar,
    sort_order      int,
    created_at      timestamptz,
    updated_at      timestamptz
);

-- 강사 수정본
CREATE TABLE material_revisions (
    id                 bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    material_id        bigint NOT NULL REFERENCES materials (id) ON DELETE CASCADE,
    author_id          bigint NOT NULL REFERENCES users (id),
    seq_no             int,
    subtitle           varchar,
    intent             text,
    file_key           varchar,
    original_filename  varchar,
    is_shared          boolean DEFAULT false,
    shared_at          timestamptz,
    created_at         timestamptz,
    updated_at         timestamptz
);

-- AI 사용 로그
CREATE TABLE ai_usage_logs (
    id             bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    user_id        bigint NOT NULL REFERENCES users (id),
    purpose        varchar CHECK (purpose IN ('MATERIAL_GEN', 'REGEN', 'OCR_GRADING', 'STUDENT_ANALYSIS')),
    input_tokens   int,
    output_tokens  int,
    result         varchar CHECK (result IN ('SUCCESS', 'FAILED')),
    created_at     timestamptz
);


-- ---------------------------------------------------------------------
-- 3. 성적
-- ---------------------------------------------------------------------

-- 모의고사 회차
CREATE TABLE mock_exams (
    id          bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    exam_year   int,
    exam_month  int,
    grade       varchar(10),
    title       varchar(100),
    created_at  timestamptz,
    updated_at  timestamptz
);

-- 문항 유형 매핑 (18~45번, 총 28행 고정)
CREATE TABLE question_type_map (
    question_no  int PRIMARY KEY,
    type_name    varchar(30)
);

-- 학생 점수 등급 (모의고사 결과)
CREATE TABLE mock_exam_results (
    id            bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    mock_exam_id  bigint NOT NULL REFERENCES mock_exams (id),
    raw_score     int,
    grade_level   int,
    created_at    timestamptz,
    updated_at    timestamptz,
    student_id    bigint NOT NULL REFERENCES students (id),
    entered_by    bigint NOT NULL REFERENCES users (id)
);

-- 틀린 문항 (mock_exam_results : question_type_map = N:M)
CREATE TABLE mock_exam_wrong_answers (
    result_id    bigint NOT NULL REFERENCES mock_exam_results (id),
    question_no  int    NOT NULL REFERENCES question_type_map (question_no),
    PRIMARY KEY (result_id, question_no)
);

-- 단어시험결과  [확인 필요] 관계 미정 — 현재 다른 테이블과 연결 없음
CREATE TABLE word_tests_results (
    id              bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    batch_key       varchar,
    title           varchar,
    test_date       date,
    total           int,
    score           int,
    status          varchar,      -- aigrading / needreview / confirmed
    ai_grading      jsonb,
    scan_file_key   varchar,
    scan_purged_at  varchar,      -- [확인 필요] 타입
    confirmed_at    timestamptz,
    created_at      timestamptz,
    updated_at      timestamptz
);


-- ---------------------------------------------------------------------
-- 4. 분석 · 리포트
-- ---------------------------------------------------------------------

-- 학생 분석 (AI 초안 → 강사 검수)
CREATE TABLE student_analyses (
    id              bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    period_start    date,
    period_end      date,
    ai_result       jsonb,
    teacher_edited  jsonb,
    status          varchar CHECK (status IN ('AI_DRAFT', 'REVIEWED')),
    reviewed_at     jsonb,        -- [확인 필요] 타입
    created_at      timestamptz,
    updated_at      timestamptz,
    student_id      bigint NOT NULL REFERENCES students (id),
    reviewed_by     bigint NOT NULL REFERENCES users (id)  -- [확인 필요] NOT NULL
);

-- 학부모 리포트
CREATE TABLE parent_reports (
    id                bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    analysis_id       bigint NOT NULL REFERENCES student_analyses (id),
    content_snapshot  jsonb,
    created_at        timestamptz,
    student_id        bigint NOT NULL REFERENCES students (id),
    author_id         bigint NOT NULL REFERENCES users (id)
);
