# Customer account identifiers

Applied account migration `20260910094542` permits customer registration with an email address, a Saudi mobile number, or both. A real password is mandatory. No synthetic email address is created. Existing email/password accounts remain compatible, and staff continue to use email identifiers.

The accepted phone forms are `05xxxxxxxx` and `+9665xxxxxxxx`. A unique normalized phone index prevents separate accounts from claiming those two forms of the same number. Production preflight found zero nonstandard phone rows and zero normalized collisions. Existing contacts are not rewritten by the migration.

Phones are login identifiers, not proof of ownership. Registration always records `verified_phone=false`. Knowing a phone number cannot log in without the password, does not authorize delivery completion and does not enable password recovery. Actual SMS verification, verified-recipient recovery and phone-ownership disputes require an approved provider and owner operating policy; none is fabricated or sent here.

Password creation requires at least 12 characters and at most 72 UTF-8 bytes to respect the existing bcrypt boundary. Password checks reject null, empty or excessively long inputs. The two phone formats share one persistent failed-attempt window. Accounts with both email and phone share the email account's existing rate window across either login alias. Ten failures block further attempts for that window. Successful login creates the existing hashed opaque session and separate CSRF value. Browser secure cookies and mobile SecureStore handling are retained.

Profile editing cannot remove the only usable login identifier. Normalized uniqueness also applies to profile updates. A formatting-only change to the same phone does not falsely revoke an already recorded verification; changing the actual number resets verification. Self-service addition/change of an email identifier and provider-backed recovery remain separate future work.

New functions remain service-only, and the normalization helper is private. The database and browser gates cover optional-email creation, alias login, uniqueness, concurrent registration, durable limits, profile safeguards and inactive/operational-account exclusions. The database and browser gates passed at d89fb4a, and API v21 is active. Existing user, order and stock fingerprints are unchanged. Android 34462074478, iOS simulator 34462074546 and Expo 34462074506 passed. Web promotion and actual device acceptance remain pending; see RELEASE-EVIDENCE.md.
