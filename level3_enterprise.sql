-- ============================================================
-- ЛАБОРАТОРНА РОБОТА №3. РІВЕНЬ 3: Розширене управління даними
-- Виконав: Мартинюк Максим Віталійович, група ІПЗ-31
-- ============================================================

-- Крок 1. Система версіонування записів
CREATE TABLE books_versions (
    version_id SERIAL PRIMARY KEY,
    book_id INTEGER NOT NULL,
    version_number INTEGER NOT NULL,
    data JSONB NOT NULL,
    valid_from TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    valid_to TIMESTAMP,
    created_by VARCHAR(100) DEFAULT CURRENT_USER,
    UNIQUE(book_id, version_number)
);

CREATE OR REPLACE FUNCTION create_book_version()
RETURNS TRIGGER AS $$
DECLARE
    v_version_number INTEGER;
BEGIN
    UPDATE books_versions
    SET valid_to = CURRENT_TIMESTAMP
    WHERE book_id = NEW.book_id AND valid_to IS NULL;

    SELECT COALESCE(MAX(version_number), 0) + 1
    INTO v_version_number
    FROM books_versions
    WHERE book_id = NEW.book_id;

    INSERT INTO books_versions (book_id, version_number, data)
    VALUES (NEW.book_id, v_version_number, row_to_json(NEW)::jsonb);

    RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

CREATE TRIGGER book_versioning_trigger
AFTER INSERT OR UPDATE ON books
FOR EACH ROW
EXECUTE FUNCTION create_book_version();

CREATE OR REPLACE FUNCTION get_book_version(p_book_id INTEGER, p_date TIMESTAMP)
RETURNS JSONB AS $$
BEGIN
    RETURN (
        SELECT data
        FROM books_versions
        WHERE book_id = p_book_id
            AND valid_from <= p_date
            AND (valid_to IS NULL OR valid_to > p_date)
        LIMIT 1
    );
END;
$$ LANGUAGE plpgsql;

UPDATE books SET available_copies = 6 WHERE book_id = 1;
UPDATE books SET available_copies = 7 WHERE book_id = 1;

SELECT version_id, book_id, version_number, data->>'available_copies' AS copies, valid_from, valid_to
FROM books_versions;

-- Крок 2. Відкладені операції
CREATE TABLE scheduled_operations (
    operation_id SERIAL PRIMARY KEY,
    operation_type VARCHAR(50) NOT NULL,
    target_table VARCHAR(50) NOT NULL,
    operation_data JSONB NOT NULL,
    scheduled_for TIMESTAMP NOT NULL,
    status VARCHAR(20) DEFAULT 'Pending' CHECK (status IN ('Pending', 'Executed', 'Failed', 'Cancelled')),
    executed_at TIMESTAMP,
    error_message TEXT,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

CREATE OR REPLACE FUNCTION execute_scheduled_operations()
RETURNS INTEGER AS $$
DECLARE
    v_operation RECORD;
    v_count INTEGER := 0;
BEGIN
    FOR v_operation IN
        SELECT * FROM scheduled_operations
        WHERE status = 'Pending' AND scheduled_for <= CURRENT_TIMESTAMP
    LOOP
        BEGIN
            CASE v_operation.operation_type
                WHEN 'UPDATE_BOOK_STATUS' THEN
                    UPDATE books
                    SET available_copies = (v_operation.operation_data->>'available_copies')::INTEGER
                    WHERE book_id = (v_operation.operation_data->>'book_id')::INTEGER;

                WHEN 'EXPIRE_RESERVATION' THEN
                    UPDATE reservations
                    SET status = 'Expired'
                    WHERE reservation_id = (v_operation.operation_data->>'reservation_id')::INTEGER;

                WHEN 'BLOCK_READER' THEN
                    UPDATE readers
                    SET status = 'Blocked'
                    WHERE reader_id = (v_operation.operation_data->>'reader_id')::INTEGER;
            END CASE;

            UPDATE scheduled_operations
            SET status = 'Executed', executed_at = CURRENT_TIMESTAMP
            WHERE operation_id = v_operation.operation_id;

            v_count := v_count + 1;
        EXCEPTION WHEN OTHERS THEN
            UPDATE scheduled_operations
            SET status = 'Failed',
                executed_at = CURRENT_TIMESTAMP,
                error_message = SQLERRM
            WHERE operation_id = v_operation.operation_id;
        END;
    END LOOP;

    RETURN v_count;
END;
$$ LANGUAGE plpgsql;

INSERT INTO scheduled_operations (operation_type, target_table, operation_data, scheduled_for)
VALUES (
    'EXPIRE_RESERVATION',
    'reservations',
    '{"reservation_id": 1}'::jsonb,
    CURRENT_TIMESTAMP - INTERVAL '1 minute'
);

SELECT execute_scheduled_operations();
SELECT operation_id, operation_type, status, executed_at FROM scheduled_operations;

-- Крок 3. Складна бізнес-логіка (extend_lending)
CREATE OR REPLACE FUNCTION extend_lending(
    p_lending_id INTEGER,
    p_days INTEGER DEFAULT 7
)
RETURNS TABLE (
    success BOOLEAN,
    message TEXT,
    new_due_date DATE
) AS $$
DECLARE
    v_reader_status VARCHAR(20);
    v_overdue_count INTEGER;
    v_current_due_date DATE;
BEGIN
    SELECT r.status, l.due_date
    INTO v_reader_status, v_current_due_date
    FROM lendings l
    JOIN readers r ON l.reader_id = r.reader_id
    WHERE l.lending_id = p_lending_id;

    IF v_reader_status = 'Blocked' THEN
        RETURN QUERY SELECT FALSE, 'Читач заблокований'::TEXT, NULL::DATE;
        RETURN;
    END IF;

    SELECT COUNT(*)
    INTO v_overdue_count
    FROM lendings l
    JOIN readers r ON l.reader_id = r.reader_id
    WHERE r.reader_id = (SELECT reader_id FROM lendings WHERE lending_id = p_lending_id)
        AND l.return_date IS NULL
        AND l.due_date < CURRENT_DATE;

    IF v_overdue_count > 0 THEN
        RETURN QUERY SELECT FALSE, 'У читача є прострочені книги'::TEXT, NULL::DATE;
        RETURN;
    END IF;

    UPDATE lendings
    SET due_date = due_date + p_days
    WHERE lending_id = p_lending_id;

    RETURN QUERY SELECT TRUE, 'Термін продовжено'::TEXT, (v_current_due_date + p_days)::DATE;
END;
$$ LANGUAGE plpgsql;

SELECT * FROM extend_lending(1, 14);

-- Крок 4. Система прав доступу
ALTER FUNCTION log_books_changes() SECURITY DEFINER;

CREATE ROLE librarian_read;
CREATE ROLE librarian_write;
CREATE ROLE library_admin;

GRANT SELECT ON ALL TABLES IN SCHEMA public TO librarian_read;

GRANT SELECT, INSERT, UPDATE ON books, lendings, reservations TO librarian_write;
GRANT DELETE ON reservations TO librarian_write;
GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA public TO librarian_write;

GRANT ALL PRIVILEGES ON ALL TABLES IN SCHEMA public TO library_admin;
GRANT ALL PRIVILEGES ON ALL SEQUENCES IN SCHEMA public TO library_admin;

CREATE USER librarian1 WITH PASSWORD 'secure_password1';
CREATE USER librarian2 WITH PASSWORD 'secure_password2';
CREATE USER admin1 WITH PASSWORD 'admin_password';

GRANT librarian_read TO librarian1;
GRANT librarian_write TO librarian2;
GRANT library_admin TO admin1;

SET ROLE librarian1;
SELECT book_id, title FROM books WHERE book_id IN (2, 3, 4);
UPDATE books SET available_copies = 5 WHERE book_id = 1;

SET ROLE librarian2;
UPDATE books SET available_copies = 5 WHERE book_id = 1;
DELETE FROM authors WHERE author_id = 1;

RESET ROLE;

-- Крок 5. Автоматичне відновлення (контрольні точки)
CREATE TABLE backup_points (
    backup_id SERIAL PRIMARY KEY,
    backup_name VARCHAR(100) NOT NULL,
    backup_timestamp TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    description TEXT,
    data_snapshot JSONB
);

CREATE OR REPLACE FUNCTION create_backup_point(p_name VARCHAR, p_description TEXT DEFAULT NULL)
RETURNS INTEGER AS $$
DECLARE
    v_backup_id INTEGER;
    v_snapshot JSONB;
BEGIN
    SELECT jsonb_build_object(
        'books', (SELECT jsonb_agg(row_to_json(b)) FROM books b),
        'authors', (SELECT jsonb_agg(row_to_json(a)) FROM authors a),
        'readers', (SELECT jsonb_agg(row_to_json(r)) FROM readers r),
        'lendings', (SELECT jsonb_agg(row_to_json(l)) FROM lendings l)
    ) INTO v_snapshot;

    INSERT INTO backup_points (backup_name, description, data_snapshot)
    VALUES (p_name, p_description, v_snapshot)
    RETURNING backup_id INTO v_backup_id;

    RETURN v_backup_id;
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION restore_from_backup(p_backup_id INTEGER)
RETURNS BOOLEAN AS $$
DECLARE
    v_snapshot JSONB;
    v_record JSONB;
BEGIN
    SELECT data_snapshot INTO v_snapshot
    FROM backup_points
    WHERE backup_id = p_backup_id;

    IF v_snapshot IS NULL THEN
        RAISE EXCEPTION 'Backup point not found';
    END IF;

    BEGIN
        TRUNCATE TABLE lendings CASCADE;
        TRUNCATE TABLE books CASCADE;
        TRUNCATE TABLE readers CASCADE;
        TRUNCATE TABLE authors CASCADE;

        FOR v_record IN SELECT * FROM jsonb_array_elements(v_snapshot->'authors')
        LOOP
            INSERT INTO authors
            SELECT * FROM jsonb_populate_record(NULL::authors, v_record);
        END LOOP;

        RETURN TRUE;
    EXCEPTION WHEN OTHERS THEN
        RAISE EXCEPTION 'Restore failed: %', SQLERRM;
        RETURN FALSE;
    END;
END;
$$ LANGUAGE plpgsql;

SELECT create_backup_point('Before major update', 'Backup before system upgrade');
SELECT backup_id, backup_name, backup_timestamp, description FROM backup_points;

-- Крок 6. Інтерфейс перегляду історії змін
CREATE OR REPLACE VIEW books_change_history AS
SELECT
    a.log_id,
    a.operation,
    a.record_id as book_id,
    COALESCE(a.new_data->>'title', a.old_data->>'title') as title,
    CASE
        WHEN a.operation = 'INSERT' THEN 'Додано нову книгу'
        WHEN a.operation = 'UPDATE' THEN
            'Оновлено: ' ||
            CASE
                WHEN a.old_data->>'available_copies' <> a.new_data->>'available_copies'
                THEN 'Доступні примірники: ' || a.old_data->>'available_copies' || ' -> ' || a.new_data->>'available_copies'
                ELSE 'Інші поля'
            END
        WHEN a.operation = 'DELETE' THEN 'Видалено книгу'
    END as change_description,
    a.changed_at,
    a.changed_by
FROM audit_log a
WHERE a.table_name = 'books'
ORDER BY a.changed_at DESC;

CREATE OR REPLACE FUNCTION get_changes_report(
    p_start_date TIMESTAMP,
    p_end_date TIMESTAMP DEFAULT CURRENT_TIMESTAMP
)
RETURNS TABLE (
    change_date DATE,
    total_changes BIGINT,
    inserts BIGINT,
    updates BIGINT,
    deletes BIGINT
) AS $$
BEGIN
    RETURN QUERY
    SELECT
        DATE(changed_at) as change_date,
        COUNT(*) as total_changes,
        COUNT(*) FILTER (WHERE operation = 'INSERT') as inserts,
        COUNT(*) FILTER (WHERE operation = 'UPDATE') as updates,
        COUNT(*) FILTER (WHERE operation = 'DELETE') as deletes
    FROM audit_log
    WHERE changed_at BETWEEN p_start_date AND p_end_date
    GROUP BY DATE(changed_at)
    ORDER BY change_date DESC;
END;
$$ LANGUAGE plpgsql;

SELECT log_id, operation, title, change_description FROM books_change_history LIMIT 5;
SELECT * FROM get_changes_report(CURRENT_DATE - INTERVAL '30 days');