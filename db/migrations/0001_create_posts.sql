CREATE TABLE `posts` (`id` integer NOT NULL PRIMARY KEY AUTOINCREMENT, `title` varchar(255) NOT NULL, `body` varchar(255), `created_at` timestamp DEFAULT (datetime(CURRENT_TIMESTAMP, 'localtime')));
