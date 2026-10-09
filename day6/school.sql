-- Day 6 assignment: school database
-- Tables: students, courses, enrolments (join table between the two)
-- Works in SQLite (e.g. sqliteonline.com). You can run the whole file again
-- and again because it drops the old tables first.

PRAGMA foreign_keys = ON;

-- Drop in this order: enrolments first, because it depends on the other two
DROP TABLE IF EXISTS enrolments;
DROP TABLE IF EXISTS courses;
DROP TABLE IF EXISTS students;


-- ============================================================
-- 1. CREATE TABLES
-- ============================================================

CREATE TABLE students (
    student_id  INTEGER PRIMARY KEY,
    first_name  TEXT NOT NULL,
    last_name   TEXT NOT NULL,
    email       TEXT NOT NULL UNIQUE      -- no two students share an email
);

CREATE TABLE courses (
    course_id   INTEGER PRIMARY KEY,
    title       TEXT NOT NULL,
    credits     INTEGER NOT NULL CHECK (credits > 0)
);

-- One row = one student enrolled on one course
CREATE TABLE enrolments (
    enrolment_id INTEGER PRIMARY KEY,
    student_id   INTEGER NOT NULL,
    course_id    INTEGER NOT NULL,
    grade        INTEGER CHECK (grade BETWEEN 0 AND 100),  -- NULL = not graded yet
    FOREIGN KEY (student_id) REFERENCES students (student_id),
    FOREIGN KEY (course_id)  REFERENCES courses (course_id),
    UNIQUE (student_id, course_id)        -- same student cannot join the same course twice
);

-- Index (explained in school-design.md): speeds up "who is on this course?"
CREATE INDEX idx_enrolments_course_id ON enrolments (course_id);


-- ============================================================
-- 2. INSERT SAMPLE DATA
-- ============================================================

INSERT INTO students (student_id, first_name, last_name, email) VALUES
    (1, 'Amara', 'Okafor', 'amara.okafor@example.com'),
    (2, 'Liam',  'Chen',   'liam.chen@example.com'),
    (3, 'Sofia', 'Rossi',  'sofia.rossi@example.com'),
    (4, 'Noah',  'Patel',  'noah.patel@example.com'),
    (5, 'Zara',  'Ahmed',  'zara.ahmed@example.com');   -- no enrolments (used in query 4)

INSERT INTO courses (course_id, title, credits) VALUES
    (1, 'Web Foundations',   4),
    (2, 'Databases',         3),
    (3, 'Mathematics',       4),
    (4, 'Meteorology Basics', 3);                        -- no students yet (shows 0 in query 3)

INSERT INTO enrolments (student_id, course_id, grade) VALUES
    (1, 1, 85),
    (1, 2, 72),
    (2, 1, 90),
    (2, 3, NULL),      -- not graded yet (updated in query 5)
    (3, 1, 68),
    (3, 2, NULL),
    (4, 2, 77),
    (4, 3, 81);


-- ============================================================
-- 3. QUERIES
-- Tip: in the playground, highlight one query and press Run to run only that one.
-- ============================================================

-- Query 1: all courses for one student (by name)
SELECT s.first_name, s.last_name, c.title, e.grade
FROM students s
JOIN enrolments e ON e.student_id = s.student_id
JOIN courses c    ON c.course_id  = e.course_id
WHERE s.first_name = 'Amara' AND s.last_name = 'Okafor'
ORDER BY c.title;

-- Query 2: all students on one course
SELECT c.title, s.first_name, s.last_name, s.email, e.grade
FROM courses c
JOIN enrolments e ON e.course_id  = c.course_id
JOIN students s   ON s.student_id = e.student_id
WHERE c.title = 'Databases'
ORDER BY s.last_name;

-- Query 3: number of students per course
-- LEFT JOIN keeps courses with no students (they show 0)
SELECT c.title, COUNT(e.enrolment_id) AS number_of_students
FROM courses c
LEFT JOIN enrolments e ON e.course_id = c.course_id
GROUP BY c.course_id, c.title
ORDER BY number_of_students DESC, c.title;

-- Query 4: students who have no enrolments
-- LEFT JOIN + IS NULL finds students with no matching row in enrolments
SELECT s.student_id, s.first_name, s.last_name, s.email
FROM students s
LEFT JOIN enrolments e ON e.student_id = s.student_id
WHERE e.enrolment_id IS NULL;

-- Query 5: update one enrolment's grade (Liam Chen, Mathematics -> 88)
UPDATE enrolments
SET grade = 88
WHERE student_id = (SELECT student_id FROM students WHERE email = 'liam.chen@example.com')
  AND course_id  = (SELECT course_id  FROM courses  WHERE title = 'Mathematics');

-- Check that the update worked
SELECT s.first_name, s.last_name, c.title, e.grade
FROM enrolments e
JOIN students s ON s.student_id = e.student_id
JOIN courses c  ON c.course_id  = e.course_id
WHERE s.email = 'liam.chen@example.com';
