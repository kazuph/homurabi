CREATE TABLE `otps` (`id` integer NOT NULL PRIMARY KEY AUTOINCREMENT, `email` varchar(255) NOT NULL, `code` varchar(255) NOT NULL, `expires_at` integer NOT NULL);
CREATE INDEX `otps_email_index` ON `otps` (`email`);
