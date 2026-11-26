-- Runs once, the first time the ticket-db container starts with an empty volume.
CREATE TABLE IF NOT EXISTS tickets (
  ticket_id       CHAR(36)     NOT NULL PRIMARY KEY,
  title           VARCHAR(200) NOT NULL,
  description     TEXT         NOT NULL,
  status          ENUM('OPEN','IN_PROGRESS','RESOLVED','CLOSED') NOT NULL DEFAULT 'OPEN',
  priority        ENUM('LOW','MEDIUM','HIGH')                    NOT NULL DEFAULT 'MEDIUM',
  requester_name  VARCHAR(100) NOT NULL,
  created_at      DATETIME     NOT NULL,
  updated_at      DATETIME     NOT NULL,
  INDEX idx_status (status)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
