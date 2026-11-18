# Classon ERD (테이블 17개)

> 엔티티·Repository·쿼리를 만들기 전에 이 문서를 기준으로 한다.
> 모든 테이블에 `created_at DATETIME NOT NULL`, `updated_at DATETIME NOT NULL`이 있다 (BaseEntity). 아래 표에서는 생략.
> enum 컬럼은 DB에 `VARCHAR(20)`, JPA는 `@Enumerated(EnumType.STRING)`.
> ON DELETE 표기가 없으면 RESTRICT(자식이 있으면 부모 삭제 거부).

## 관계 한눈에 보기

```
users ─┬─< classes ─────< students ─┬─< student_memos           (>─ users: author_id)
       │       │                    ├─< word_test_results       (>─ users: teacher_id, confirmed_by)
       │       └──────────────────< ┘   (class_id, NULL 허용)
       │                            ├─< mock_exam_results ─< mock_exam_wrong_answers >─ question_type_map >─ question_types
       │                            │        >─ mock_exams
       │                            ├─< student_analyses ─< parent_reports
       │                            └─< parent_reports
       │
       ├─< source_passages ─< materials ─┬─< vocab_entries        (CASCADE)
       │     (prev_version_id: 자기참조)  └─< material_revisions   (CASCADE)
       │
       └─< ai_usage_logs
```

## 도메인별 테이블

| 도메인 | 테이블 |
|---|---|
| user | users |
| classroom | classes |
| student | students, student_memos |
| material | source_passages, materials, vocab_entries, material_revisions |
| wordtest | word_test_results |
| mockexam | question_types, question_type_map, mock_exams, mock_exam_results, mock_exam_wrong_answers |
| analysis | student_analyses |
| report | parent_reports |
| common | ai_usage_logs |

---

## 1. users (사용자)

| 컬럼 | 타입 | NULL | 키 | 설명 |
|---|---|---|---|---|
| id | BIGINT | N | PK | 자동 증가 |
| login_id | VARCHAR(50) | N | UK | 로그인 아이디 |
| password_hash | VARCHAR(255) | N | | BCrypt |
| name | VARCHAR(30) | N | | 표시 이름 (수정본 "홍길동강사Ver1"에 사용) |
| role | VARCHAR(20) | N | | ADMIN / TEACHER |
| status | VARCHAR(20) | N | | ACTIVE / INACTIVE. INACTIVE는 로그인 차단 |

- 삭제하지 않는다. 퇴사 시 INACTIVE.

## 2. classes (반)

| 컬럼 | 타입 | NULL | 키 | 설명 |
|---|---|---|---|---|
| id | BIGINT | N | PK | |
| teacher_id | BIGINT | N | FK → users.id | 담당 강사 |
| name | VARCHAR(50) | N | | 반 이름 (예: top1, middle1) |
| grade | VARCHAR(10) | Y | | 학년 필터용 |
| is_active | BOOLEAN | N | | 기본 true. 폐강 시 false |

- 이름 중복은 "활성 반 중에서만" 서비스에서 검사 (DB UK 아님).

## 3. students (학생)

| 컬럼 | 타입 | NULL | 키 | 설명 |
|---|---|---|---|---|
| id | BIGINT | N | PK | AI 전송 시 쓰는 내부 ID |
| class_id | BIGINT | Y | FK → classes.id, **SET NULL** | 현재 반. NULL = 미배정 |
| name | VARCHAR(30) | N | | 식별정보 (AI 전송 금지) |
| school_name | VARCHAR(50) | Y | | 식별정보 (AI 전송 금지) |
| grade | VARCHAR(10) | Y | | 학년 |
| phone | VARCHAR(20) | Y | | 식별정보 (AI 전송 금지) |
| parent_phone | VARCHAR(20) | Y | | 식별정보 (AI 전송 금지) |
| status | VARCHAR(20) | N | | ACTIVE / INACTIVE(퇴원) |
| deleted_at | DATETIME | Y | | soft delete 시각 |

- 실제 DELETE 금지. 조회는 `deleted_at IS NULL` (`@SQLRestriction` 권장).
- 반 배정 이력은 저장하지 않는다.

## 4. student_memos (학생 메모)

| 컬럼 | 타입 | NULL | 키 | 설명 |
|---|---|---|---|---|
| id | BIGINT | N | PK | |
| student_id | BIGINT | N | FK → students.id | |
| author_id | BIGINT | N | FK → users.id | 작성 강사 |
| content | TEXT | N | | 자유 입력. AI 전송 시 마스킹 |

## 5. source_passages (원본 지문)

| 컬럼 | 타입 | NULL | 키 | 설명 |
|---|---|---|---|---|
| id | BIGINT | N | PK | |
| origin | VARCHAR(20) | N | | OFFICIAL(관리자) / PERSONAL(강사) |
| uploader_id | BIGINT | N | FK → users.id | 올린 사람. 개인 자료의 소유자 |
| title | VARCHAR(200) | N | | 자료찾기 표시명. 새 버전은 "(수정본)" 표시 |
| category | VARCHAR(20) | N | | MOCK_EXAM / TEXTBOOK / OTHER |
| grade | VARCHAR(10) | Y | | |
| exam_year | SMALLINT | Y | | 모의고사만 |
| exam_month | TINYINT | Y | | 모의고사만 |
| question_no | TINYINT | Y | | 모의고사 문항 번호 (예: 31) |
| publisher | VARCHAR(50) | Y | | 교과서만 |
| unit_label | VARCHAR(50) | Y | | 교과서 단원 (자유 텍스트) |
| passage_text | LONGTEXT | N | | AI에 보내는 지문 본문 |
| file_key | VARCHAR(255) | Y | | 업로드 원본 파일 경로 |
| extra_prompt | TEXT | Y | | 추가 프롬프트. 재생성 시 재사용 |
| status | VARCHAR(20) | N | | GENERATING / REVIEW / CONFIRMED / FAILED |
| confirmed_by | BIGINT | Y | FK → users.id | 확정한 사람 |
| confirmed_at | DATETIME | Y | | 확정 시각. 자료찾기 정렬 기준 |
| prev_version_id | BIGINT | Y | FK → source_passages.id, **SET NULL** | 이전 버전 원본 |

## 6. materials (생성 자료)

| 컬럼 | 타입 | NULL | 키 | 설명 |
|---|---|---|---|---|
| id | BIGINT | N | PK | |
| source_passage_id | BIGINT | N | FK → source_passages.id, **CASCADE** | |
| material_type | VARCHAR(20) | N | | VOCAB / ANALYSIS / LESSON |
| gen_status | VARCHAR(20) | N | | GENERATING / SUCCESS / FAILED |
| content_json | JSON | Y | | AI 생성 결과. 미리보기·간단 수정 대상 |
| file_key | VARCHAR(255) | Y | | 확정 시 만든 docx |
| regen_count | INT | N | | 기본 0 |
| is_shared | BOOLEAN | N | | 개인 자료 공유 여부. 기본 false. 공식 자료는 쓰지 않음 |
| shared_at | DATETIME | Y | | |

- **UK (source_passage_id, material_type)**: 원본 하나에 종류별 하나.

## 7. vocab_entries (단어)

| 컬럼 | 타입 | NULL | 키 | 설명 |
|---|---|---|---|---|
| id | BIGINT | N | PK | |
| material_id | BIGINT | N | FK → materials.id, **CASCADE** | VOCAB 자료만 |
| word | VARCHAR(100) | N | | 표제어 (숙어 포함) |
| meaning | VARCHAR(255) | N | | 지문 속 문맥의 뜻 |
| part_of_speech | VARCHAR(20) | Y | | |
| example_sentence | TEXT | Y | | 지문 원문 문장 |
| sort_order | INT | N | | 지문 등장 순서 |

- **UK (material_id, word)**
- 확정(MAT-07) 시 VOCAB의 `content_json`을 풀어서 저장한다. 확정 전에는 비어 있다.

## 8. material_revisions (강사 수정본)

| 컬럼 | 타입 | NULL | 키 | 설명 |
|---|---|---|---|---|
| id | BIGINT | N | PK | |
| material_id | BIGINT | N | FK → materials.id, **CASCADE** | 기준 공식 자료 |
| author_id | BIGINT | N | FK → users.id | 작성 강사 (소유자) |
| seq_no | INT | N | | 같은 자료·같은 강사 기준 순번 (Ver1, Ver2…) |
| subtitle | VARCHAR(100) | N | | 수정 내용. 표시 파일명에 사용 |
| intent | TEXT | Y | | 수정 의도 (선택) |
| file_key | VARCHAR(255) | N | | 업로드 docx |
| original_filename | VARCHAR(255) | N | | 업로드 당시 파일명 |
| is_shared | BOOLEAN | N | | 기본 false |
| shared_at | DATETIME | Y | | |

- **UK (material_id, author_id, seq_no)**
- 부모 수정본 컬럼이 없다 → 수정본의 수정본 금지가 구조로 보장된다.
- 표시 파일명은 저장하지 않고 계산: `{기존파일명}({subtitle})_{users.name}강사Ver{seq_no}.docx`

## 9. word_test_results (단어시험 결과)

> 시험지·정답지 테이블은 없다. 시험 정보는 결과 행에 복사하고, 한 번에 올린 묶음은 `batch_key`로 구분한다.

| 컬럼 | 타입 | NULL | 키 | 설명 |
|---|---|---|---|---|
| id | BIGINT | N | PK | |
| student_id | BIGINT | N | FK → students.id | |
| teacher_id | BIGINT | N | FK → users.id | 스캔본을 올린 강사 |
| class_id | BIGINT | Y | FK → classes.id, **SET NULL** | 시험 본 반. 합동·보충 시험은 NULL |
| batch_key | VARCHAR(36) | N | | 한 번에 올린 묶음 (UUID) |
| title | VARCHAR(100) | N | | 시험명 |
| test_date | DATE | N | | 시험 날짜. 그래프 x축 |
| total | INT | N | | 전체 문항 수 |
| score | INT | Y | | 맞은 수. AI 채점 전 NULL. `ai_grading`에서 계산 |
| status | VARCHAR(20) | N | | AI_GRADING / NEEDS_REVIEW / CONFIRMED |
| ai_grading | JSON | Y | | 문항별 판독·정오·불확실 여부 |
| scan_file_key | VARCHAR(255) | Y | | 스캔본. 파기 후 NULL |
| scan_purged_at | DATETIME | Y | | 스캔본 파기 시각 |
| confirmed_by | BIGINT | Y | FK → users.id | 2차 채점 확정자 |
| confirmed_at | DATETIME | Y | | |

- **UK (batch_key, student_id)**
- **INDEX (student_id, status, test_date)**: 학생 그래프 조회용
- 성적으로 쓰는 것은 `status = CONFIRMED`만.

## 10. question_types (문항 유형)

| 컬럼 | 타입 | NULL | 키 | 설명 |
|---|---|---|---|---|
| id | BIGINT | N | PK | |
| name | VARCHAR(30) | N | UK | 예: 빈칸 추론, 순서 배열 |
| section | VARCHAR(20) | N | | LISTENING / READING |

## 11. question_type_map (문항 번호 → 유형)

| 컬럼 | 타입 | NULL | 키 | 설명 |
|---|---|---|---|---|
| question_no | TINYINT | N | PK | 1~45 |
| question_type_id | BIGINT | N | FK → question_types.id | |

- 2019년 이후 모의고사는 같은 번호면 같은 유형이라는 전제. 초기 데이터는 SQL로 넣는다.

## 12. mock_exams (모의고사 회차)

| 컬럼 | 타입 | NULL | 키 | 설명 |
|---|---|---|---|---|
| id | BIGINT | N | PK | |
| exam_year | SMALLINT | N | | |
| exam_month | TINYINT | N | | |
| grade | VARCHAR(10) | N | | |
| title | VARCHAR(100) | N | | 표시명 |

- **UK (exam_year, exam_month, grade)**

## 13. mock_exam_results (학생별 모의고사 성적)

| 컬럼 | 타입 | NULL | 키 | 설명 |
|---|---|---|---|---|
| id | BIGINT | N | PK | |
| mock_exam_id | BIGINT | N | FK → mock_exams.id | |
| student_id | BIGINT | N | FK → students.id | |
| raw_score | INT | N | | 원점수 0~100 |
| grade_level | TINYINT | N | | 등급 1~9 |
| entered_by | BIGINT | N | FK → users.id | 입력한 강사 |

- **UK (mock_exam_id, student_id)**

## 14. mock_exam_wrong_answers (틀린 문항)

| 컬럼 | 타입 | NULL | 키 | 설명 |
|---|---|---|---|---|
| result_id | BIGINT | N | PK, FK → mock_exam_results.id, **CASCADE** | |
| question_no | TINYINT | N | PK, FK → question_type_map.question_no | |

- 식별 관계 (복합 PK). 틀린 번호만 저장, 없는 번호는 정답.
- 미결정: 미응시 구분이 필요하면 `mark VARCHAR(20)` (WRONG / UNANSWERED) 추가.

## 15. student_analyses (AI 학습 분석)

| 컬럼 | 타입 | NULL | 키 | 설명 |
|---|---|---|---|---|
| id | BIGINT | N | PK | |
| student_id | BIGINT | N | FK → students.id | |
| requested_by | BIGINT | N | FK → users.id | 요청·검수 강사 |
| period_start | DATE | N | | 분석 기간 |
| period_end | DATE | N | | |
| ai_result | JSON | Y | | AI 원문. 수정하지 않음 |
| teacher_edited | JSON | Y | | 강사 검수본 |
| status | VARCHAR(20) | N | | AI_DRAFT / REVIEWED |
| reviewed_at | DATETIME | Y | | |

## 16. parent_reports (학부모 리포트)

| 컬럼 | 타입 | NULL | 키 | 설명 |
|---|---|---|---|---|
| id | BIGINT | N | PK | |
| student_id | BIGINT | N | FK → students.id | |
| analysis_id | BIGINT | Y | FK → student_analyses.id, **SET NULL** | REVIEWED 분석만 연결 |
| author_id | BIGINT | N | FK → users.id | |
| period_start | DATE | N | | |
| period_end | DATE | N | | |
| content_snapshot | JSON | N | | 생성 시점의 성적·코멘트 복사본 |
| file_key | VARCHAR(255) | N | | |
| file_format | VARCHAR(10) | N | | DOCX / PDF |

- 전부 보존. 생성 후 내용이 바뀌지 않는다.

## 17. ai_usage_logs (AI 사용량)

| 컬럼 | 타입 | NULL | 키 | 설명 |
|---|---|---|---|---|
| id | BIGINT | N | PK | |
| user_id | BIGINT | N | FK → users.id | 호출을 일으킨 사용자 |
| purpose | VARCHAR(30) | N | | MATERIAL_GEN / REGEN / WORD_GRADING / STUDENT_ANALYSIS |
| model | VARCHAR(50) | N | | 사용한 모델 이름 |
| input_tokens | INT | N | | |
| output_tokens | INT | N | | |
| result | VARCHAR(20) | N | | SUCCESS / FAILED |

- 프롬프트·응답 원문, 학생 id 컬럼을 일부러 두지 않는다.

---

## 삭제 규칙 요약

| 대상 | 방식 | 같이 일어나는 일 |
|---|---|---|
| source_passages | 실제 삭제 | materials → vocab_entries, material_revisions CASCADE. 저장소 파일도 삭제. 새 버전의 prev_version_id SET NULL. 단어시험 점수 영향 없음 |
| material_revisions | 실제 삭제 | 저장소 파일 삭제 |
| students | soft delete | 성적·메모·리포트 유지 |
| users | INACTIVE | 작성 자료 유지 |
| classes | is_active = false | (실제 삭제 시 students.class_id, word_test_results.class_id SET NULL) |
| mock_exam_results | 실제 삭제 (성적 정정) | mock_exam_wrong_answers CASCADE |
| 스캔본 파일 | 파일만 삭제 | scan_file_key NULL, scan_purged_at 기록 |
