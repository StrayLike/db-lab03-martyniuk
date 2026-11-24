-- ============================================================
-- ЛАБОРАТОРНА РОБОТА №3. РІВЕНЬ 2: Розширена функціональність
-- Виконав: Мартинюк Максим Віталійович, група ІПЗ-31
-- ============================================================

-- Крок 1. Додавання нових таблиць (reservations та audit_log)
CREATE TABLE reservations (
    reservation_id SERIAL PRIMARY KEY,
    book_id INTEGER NOT NULL,
    reader_id INTEGER NOT NULL,
    reservation_date TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    expiration_date TIMESTAMP NOT NULL,
    status VARCHAR(20) DEFAULT 'Active' CHECK (status IN ('Active', 'Fulfilled', 'Cancelled', 'Expired')),
    FOREIGN KEY (book_id) REFERENCES books(book_id) ON DELETE CASCADE,
    FOREIGN KEY (reader_id) REFERENCES readers(reader_id) ON DELETE CASCADE
);

CREATE TABLE audit_log (
    log_id SERIAL PRIMARY KEY,
    table_name VARCHAR(50) NOT NULL,
    operation VARCHAR(10) NOT NULL,
    record_id INTEGER NOT NULL,
    old_data JSONB,
    new_data JSONB,
    changed_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    changed_by VARCHAR(100) DEFAULT CURRENT_USER
);

-- Крок 2. Складні транзакції (повернення книги + виконання бронювання)
INSERT INTO reservations (book_id, reader_id, expiration_date)
VALUES (1, 2, CURRENT_TIMESTAMP + INTERVAL '7 days');

BEGIN;

UPDATE lendings
SET return_date = CURRENT_DATE
WHERE lending_id = 1 AND return_date IS NULL;

UPDATE books
SET available_copies = available_copies + 1
WHERE book_id = (SELECT book_id FROM lendings WHERE lending_id = 1);

UPDATE reservations
SET status = 'Fulfilled'
WHERE reservation_id = (
    SELECT reservation_id
    FROM reservations
    WHERE book_id = (SELECT book_id FROM lendings WHERE lending_id = 1)
        AND status = 'Active'
    ORDER BY reservation_date
    LIMIT 1
);

COMMIT;

SELECT reservation_id, book_id, reader_id, status FROM reservations;

-- Крок 3. Використання SAVEPOINT
BEGIN;

INSERT INTO authors (first_name, last_name, birth_year, country)
VALUES ('Ольга', 'Кобилянська', 1863, 'Україна');

SAVEPOINT after_author;

INSERT INTO books (isbn, title, author_id, publication_year, genre, total_copies, available_copies)
VALUES ('978-966-03-4566-7', 'Земля', currval('authors_author_id_seq'), 1902, 'Роман', 3, 3);

SAVEPOINT after_book;

-- Спроба вставити дублікат ISBN (викличе помилку)
INSERT INTO books (isbn, title, author_id, publication_year, genre)
VALUES ('978-966-03-4566-7', 'Інша книга', currval('authors_author_id_seq'), 1905, 'Роман');

ROLLBACK TO SAVEPOINT after_author;

INSERT INTO books (isbn, title, author_id, publication_year, genre, total_copies, available_copies)
VALUES ('978-966-03-4567-4', 'Земля', currval('authors_author_id_seq'), 1902, 'Роман', 3, 3);

COMMIT;

SELECT book_id, isbn, title FROM books WHERE isbn = '978-966-03-4567-4';

-- Крок 4. Каскадні операції (ON DELETE CASCADE)
BEGIN;

INSERT INTO authors (first_name, last_name, birth_year, country)
VALUES ('Тестовий', 'Автор', 1900, 'Україна');

INSERT INTO books (isbn, title, author_id, publication_year, genre, total_copies, available_copies)
VALUES ('978-966-00-0000-0', 'Тестова книга', currval('authors_author_id_seq'), 2000, 'Тест', 1, 0);

INSERT INTO reservations (book_id, reader_id, expiration_date)
VALUES (currval('books_book_id_seq'), 1, CURRENT_TIMESTAMP + INTERVAL '7 days');

COMMIT;

SELECT b.book_id, b.title, r.reservation_id
FROM books b
LEFT JOIN reservations r ON b.book_id = r.book_id
WHERE b.isbn = '978-966-00-0000-0';

DELETE FROM books WHERE isbn = '978-966-00-0000-0';

SELECT * FROM reservations WHERE book_id NOT IN (SELECT book_id FROM books);

-- Крок 5. Тригери для аудиту
CREATE OR REPLACE FUNCTION log_books_changes()
RETURNS TRIGGER AS $$
BEGIN
    IF TG_OP = 'INSERT' THEN
        INSERT INTO audit_log (table_name, operation, record_id, new_data)
        VALUES ('books', 'INSERT', NEW.book_id, row_to_json(NEW)::jsonb);
    ELSIF TG_OP = 'UPDATE' THEN
        INSERT INTO audit_log (table_name, operation, record_id, old_data, new_data)
        VALUES ('books', 'UPDATE', NEW.book_id, row_to_json(OLD)::jsonb, row_to_json(NEW)::jsonb);
    ELSIF TG_OP = 'DELETE' THEN
        INSERT INTO audit_log (table_name, operation, record_id, old_data)
        VALUES ('books', 'DELETE', OLD.book_id, row_to_json(OLD)::jsonb);
    END IF;
    RETURN NULL;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER books_audit_trigger
AFTER INSERT OR UPDATE OR DELETE ON books
FOR EACH ROW
EXECUTE FUNCTION log_books_changes();

UPDATE books SET available_copies = available_copies + 1 WHERE book_id = 1;

SELECT log_id, operation, record_id,
      new_data->>'title' as title,
      old_data->>'available_copies' as old_copies,
      new_data->>'available_copies' as new_copies,
      changed_at
FROM audit_log
WHERE table_name = 'books'
ORDER BY changed_at DESC;

-- Крок 6. Блокування записів (виконується у двох паралельних сесіях)
-- Сесія 1:
BEGIN;
SELECT book_id, title, available_copies FROM books WHERE book_id = 1 FOR UPDATE;
SELECT pg_sleep(10);
UPDATE books SET available_copies = available_copies - 1 WHERE book_id = 1;
COMMIT;

-- Сесія 2:
-- BEGIN;
-- SELECT book_id, title, available_copies FROM books WHERE book_id = 1 FOR UPDATE;
-- UPDATE books SET available_copies = available_copies - 1 WHERE book_id = 1;
-- COMMIT;