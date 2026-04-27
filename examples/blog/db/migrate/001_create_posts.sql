CREATE TABLE IF NOT EXISTS `posts` (`id` integer NOT NULL PRIMARY KEY AUTOINCREMENT, `title` varchar(255) NOT NULL, `body` varchar(255) DEFAULT ('') NOT NULL, `created_at` integer NOT NULL);
