CREATE TABLE IF NOT EXISTS `todos` (`id` integer NOT NULL PRIMARY KEY AUTOINCREMENT, `title` varchar(255) NOT NULL, `done` integer DEFAULT (0) NOT NULL, `created_at` integer NOT NULL);
