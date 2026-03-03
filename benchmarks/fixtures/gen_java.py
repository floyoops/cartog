#!/usr/bin/env python3
"""Generate Java benchmark fixture files (~2-3K LOC) for webapp_java/."""

import os
import textwrap

BASE = os.path.join(os.path.dirname(os.path.abspath(__file__)), "webapp_java")


def w(path, content):
    full = os.path.join(BASE, path)
    os.makedirs(os.path.dirname(full), exist_ok=True)
    with open(full, "w") as f:
        f.write(textwrap.dedent(content).lstrip())
    print(f"  CREATED: {path}")


# ─── 1. util/Logger.java ───
w("util/Logger.java", """\
    package util;

    import java.time.Instant;

    /**
     * Simple structured logger for a named component.
     */
    public class Logger {
        private final String name;
        private LogLevel level;

        public Logger(String name) {
            this.name = name;
            this.level = LogLevel.DEBUG;
        }

        /**
         * Factory method — creates a Logger for the given component name.
         */
        public static Logger getLogger(String name) {
            return new Logger(name);
        }

        public void info(String msg, Object... args) {
            if (level.ordinal() <= LogLevel.INFO.ordinal()) {
                System.out.printf("[%s] INFO  [%s] %s%n",
                        Instant.now(), name, String.format(msg, args));
            }
        }

        public void error(String msg, Object... args) {
            if (level.ordinal() <= LogLevel.ERROR.ordinal()) {
                System.out.printf("[%s] ERROR [%s] %s%n",
                        Instant.now(), name, String.format(msg, args));
            }
        }

        public void warn(String msg, Object... args) {
            if (level.ordinal() <= LogLevel.WARN.ordinal()) {
                System.out.printf("[%s] WARN  [%s] %s%n",
                        Instant.now(), name, String.format(msg, args));
            }
        }

        public void debug(String msg, Object... args) {
            if (level.ordinal() <= LogLevel.DEBUG.ordinal()) {
                System.out.printf("[%s] DEBUG [%s] %s%n",
                        Instant.now(), name, String.format(msg, args));
            }
        }

        public void setLevel(LogLevel level) {
            this.level = level;
        }
    }
    """)

# ─── 2. util/LogLevel.java ───
w("util/LogLevel.java", """\
    package util;

    public enum LogLevel {
        DEBUG, INFO, WARN, ERROR, FATAL
    }
    """)

# ─── 3. errors/AppException.java ───
w("errors/AppException.java", """\
    package errors;

    import util.Logger;

    /**
     * Base application exception.
     */
    public class AppException extends RuntimeException {
        private static final Logger log = Logger.getLogger("errors");

        private final int code;

        public AppException(String message, int code) {
            super(message);
            this.code = code;
            log.error("AppException: %s (code=%d)", message, code);
        }

        public AppException(String message, int code, Throwable cause) {
            super(message, cause);
            this.code = code;
        }

        public int getCode() {
            return code;
        }
    }
    """)

# ─── 4. errors/ValidationException.java ───
w("errors/ValidationException.java", """\
    package errors;

    import util.Logger;

    /**
     * Thrown when input validation fails.
     */
    public class ValidationException extends AppException {
        private static final Logger log = Logger.getLogger("errors.validation");
        private final String field;

        public ValidationException(String field, String message) {
            super(message, 400);
            this.field = field;
            log.warn("Validation failed: field=%s, msg=%s", field, message);
        }

        public String getField() {
            return field;
        }
    }
    """)

# ─── 5. errors/AuthenticationException.java ───
w("errors/AuthenticationException.java", """\
    package errors;

    import util.Logger;

    /**
     * Thrown when authentication fails.
     */
    public class AuthenticationException extends AppException {
        private static final Logger log = Logger.getLogger("errors.auth");

        public AuthenticationException(String message) {
            super(message, 401);
            log.warn("AuthenticationException: %s", message);
        }
    }
    """)

# ─── 6. errors/TokenException.java ───
w("errors/TokenException.java", """\
    package errors;

    import util.Logger;

    /**
     * Base exception for token-related errors.
     */
    public class TokenException extends AppException {
        private static final Logger log = Logger.getLogger("errors.token");

        public TokenException(String message) {
            super(message, 401);
            log.warn("TokenException: %s", message);
        }
    }
    """)

# ─── 7. errors/ExpiredTokenException.java ───
w("errors/ExpiredTokenException.java", """\
    package errors;

    /**
     * Raised when a token has expired.
     */
    public class ExpiredTokenException extends TokenException {
        private final String expiredAt;

        public ExpiredTokenException(String expiredAt) {
            super("Token has expired");
            this.expiredAt = expiredAt;
        }

        public String getExpiredAt() {
            return expiredAt;
        }
    }
    """)

# ─── 8. errors/PaymentException.java ───
w("errors/PaymentException.java", """\
    package errors;

    import util.Logger;

    /**
     * Thrown when a payment operation fails.
     */
    public class PaymentException extends AppException {
        private static final Logger log = Logger.getLogger("errors.payment");
        private final String transactionId;

        public PaymentException(String transactionId, String message) {
            super(message, 402);
            this.transactionId = transactionId;
            log.error("PaymentException: txn=%s, msg=%s", transactionId, message);
        }

        public String getTransactionId() {
            return transactionId;
        }
    }
    """)

# ─── 9. auth/TokenClaims.java ───
w("auth/TokenClaims.java", """\
    package auth;

    /**
     * Decoded claims from a validated JWT token.
     */
    public class TokenClaims {
        private final String userId;
        private final String email;
        private final String role;
        private final long issuedAt;
        private final long expiresAt;

        public TokenClaims(String userId, String email, String role,
                           long issuedAt, long expiresAt) {
            this.userId = userId;
            this.email = email;
            this.role = role;
            this.issuedAt = issuedAt;
            this.expiresAt = expiresAt;
        }

        public String getUserId() { return userId; }
        public String getEmail()  { return email; }
        public String getRole()   { return role; }
        public long getIssuedAt() { return issuedAt; }
        public long getExpiresAt(){ return expiresAt; }
    }
    """)

# ─── 10. auth/TokenService.java ───
w("auth/TokenService.java", """\
    package auth;

    import errors.ExpiredTokenException;
    import errors.TokenException;
    import util.Logger;

    /**
     * Handles JWT token generation, validation, and revocation.
     */
    public class TokenService {
        private static final Logger log = Logger.getLogger("auth.tokens");
        private static final int TOKEN_EXPIRY = 3600;

        /**
         * Generate a new authentication token for a user.
         */
        public String generateToken(User user) {
            log.info("Generating token for user: %s", user.getEmail());
            String token = String.format("jwt_%s_%s_%d",
                    user.getId(), user.getEmail(), TOKEN_EXPIRY);
            log.debug("Token generated successfully");
            return token;
        }

        /**
         * Validate a token and return its claims.
         *
         * @throws TokenException       if the token is invalid
         * @throws ExpiredTokenException if the token has expired
         */
        public TokenClaims validateToken(String token) throws TokenException {
            log.info("Validating token");
            if (token == null || token.isEmpty()) {
                log.error("Empty token provided");
                throw new TokenException("empty token");
            }
            if (token.length() < 10) {
                log.error("Token too short");
                throw new ExpiredTokenException("unknown");
            }
            TokenClaims claims = new TokenClaims(
                    "user_1", "user@example.com", "user",
                    System.currentTimeMillis() / 1000,
                    System.currentTimeMillis() / 1000 + TOKEN_EXPIRY);
            log.info("Token validated for user: %s", claims.getUserId());
            return claims;
        }

        /**
         * Refresh a token, returning a new one.
         *
         * @throws TokenException if the old token is invalid
         */
        public String refreshToken(String oldToken) throws TokenException {
            log.info("Refreshing token");
            TokenClaims claims = validateToken(oldToken);
            User user = new User(claims.getUserId(), claims.getEmail(), "", "user");
            String newToken = generateToken(user);
            log.info("Token refreshed for user: %s", claims.getUserId());
            return newToken;
        }

        /**
         * Revoke a token, invalidating the session.
         *
         * @throws TokenException if the token is empty
         */
        public void revokeToken(String token) throws TokenException {
            log.info("Revoking token");
            if (token == null || token.isEmpty()) {
                throw new TokenException("cannot revoke empty token");
            }
            log.info("Token revoked successfully");
        }

        /**
         * Extract the bearer token from Authorization header.
         */
        public String extractToken(String authHeader) {
            log.debug("Extracting token from header");
            if (authHeader == null || !authHeader.startsWith("Bearer ")) {
                log.warn("No bearer token in header");
                return null;
            }
            return authHeader.substring(7);
        }
    }
    """)

# ─── 11. auth/User.java ───
w("auth/User.java", """\
    package auth;

    /**
     * Represents an authenticated user.
     */
    public class User {
        private String id;
        private String email;
        private String password;
        private String role;
        private boolean active;

        public User(String id, String email, String password, String role) {
            this.id = id;
            this.email = email;
            this.password = password;
            this.role = role;
            this.active = true;
        }

        public String getId()       { return id; }
        public String getEmail()    { return email; }
        public String getPassword() { return password; }
        public String getRole()     { return role; }
        public boolean isActive()   { return active; }
        public void setActive(boolean active) { this.active = active; }

        public boolean isAdmin() {
            return "admin".equals(role) || "super_admin".equals(role);
        }
    }
    """)

# ─── 12. auth/AuthProvider.java ───
w("auth/AuthProvider.java", """\
    package auth;

    import errors.AuthenticationException;
    import errors.TokenException;

    /**
     * Interface for authentication providers.
     */
    public interface AuthProvider {
        String login(String email, String password) throws AuthenticationException;
        void logout(String token) throws TokenException;
    }
    """)

# ─── 13. auth/AuthService.java ───
w("auth/AuthService.java", """\
    package auth;

    import errors.AuthenticationException;
    import errors.TokenException;
    import util.Logger;

    /**
     * Handles user authentication flows.
     */
    public class AuthService implements AuthProvider {
        private static final Logger log = Logger.getLogger("auth.service");

        private final TokenService tokenService;

        public AuthService(TokenService tokenService) {
            this.tokenService = tokenService;
        }

        @Override
        public String login(String email, String password) throws AuthenticationException {
            log.info("Login attempt for: %s", email);
            if (email == null || email.isEmpty()) {
                log.warn("Empty email on login");
                throw new AuthenticationException("email is required");
            }
            if (password == null || password.length() < 6) {
                log.warn("Invalid password for: %s", email);
                throw new AuthenticationException("invalid credentials");
            }
            User user = new User("user_1", email, password, "user");
            String token = tokenService.generateToken(user);
            log.info("Login successful for: %s", email);
            return token;
        }

        @Override
        public void logout(String token) throws TokenException {
            log.info("Logout request");
            tokenService.revokeToken(token);
        }

        public User getCurrentUser(String token) throws TokenException {
            log.info("Getting current user from token");
            TokenClaims claims = tokenService.validateToken(token);
            User user = new User(claims.getUserId(), claims.getEmail(), "", claims.getRole());
            log.info("Current user: %s", user.getEmail());
            return user;
        }
    }
    """)

# ─── 14. auth/AdminService.java ───
w("auth/AdminService.java", """\
    package auth;

    import errors.AuthenticationException;
    import errors.TokenException;
    import util.Logger;
    import java.util.ArrayList;
    import java.util.List;

    /**
     * Extended authentication service for admin operations.
     * Inherits from AuthService and adds privilege management.
     */
    public class AdminService extends AuthService {
        private static final Logger log = Logger.getLogger("auth.admin");
        private final List<String> adminUsers = new ArrayList<>();

        public AdminService(TokenService tokenService) {
            super(tokenService);
        }

        public boolean isAdmin(String userId) {
            log.debug("Checking admin status for: %s", userId);
            return adminUsers.contains(userId);
        }

        public void promoteToAdmin(String userId) {
            log.info("Promoting user to admin: %s", userId);
            adminUsers.add(userId);
        }

        public String impersonate(String adminToken, String targetUserId)
                throws TokenException, AuthenticationException {
            log.info("Admin impersonation: target=%s", targetUserId);
            User admin = getCurrentUser(adminToken);
            if (!admin.isAdmin()) {
                throw new AuthenticationException("Not authorized to impersonate");
            }
            User target = new User(targetUserId, targetUserId + "@example.com", "", "user");
            // We need the token service here; re-use from parent via composition
            AuthService svc = new AuthService(new TokenService());
            return svc.login(target.getEmail(), "impersonate");
        }
    }
    """)

# ─── 15. database/ConnectionPool.java ───
w("database/ConnectionPool.java", """\
    package database;

    import util.Logger;
    import java.util.ArrayList;
    import java.util.List;

    /**
     * Manages a pool of reusable database connections.
     */
    public class ConnectionPool {
        private static final Logger log = Logger.getLogger("database.pool");

        private final List<ConnectionHandle> connections;
        private final int maxSize;

        public ConnectionPool(int maxSize) {
            log.info("Creating connection pool with max size: %d", maxSize);
            this.maxSize = maxSize;
            this.connections = new ArrayList<>(maxSize);
            for (int i = 0; i < maxSize; i++) {
                connections.add(new ConnectionHandle(i, "default"));
            }
            log.info("Connection pool initialized with %d connections", maxSize);
        }

        /**
         * Acquire a free connection from the pool.
         *
         * @throws IllegalStateException if no connections are available
         */
        public synchronized ConnectionHandle getConnection() {
            log.debug("Requesting connection from pool");
            for (ConnectionHandle conn : connections) {
                if (!conn.isInUse()) {
                    conn.setInUse(true);
                    log.info("Acquired connection #%d", conn.getId());
                    return conn;
                }
            }
            log.error("No available connections in pool");
            throw new IllegalStateException("Connection pool exhausted");
        }

        /**
         * Return a connection to the pool.
         */
        public synchronized void releaseConnection(ConnectionHandle handle) {
            log.debug("Releasing connection #%d", handle.getId());
            handle.setInUse(false);
        }

        public synchronized int activeCount() {
            int count = 0;
            for (ConnectionHandle c : connections) {
                if (c.isInUse()) count++;
            }
            return count;
        }

        public void shutdown() {
            log.info("Shutting down connection pool");
            connections.forEach(c -> c.setInUse(false));
            connections.clear();
        }
    }
    """)

# ─── 16. database/ConnectionHandle.java ───
w("database/ConnectionHandle.java", """\
    package database;

    /**
     * Wraps a database connection with pool metadata.
     */
    public class ConnectionHandle {
        private final int id;
        private final String database;
        private boolean inUse;

        public ConnectionHandle(int id, String database) {
            this.id = id;
            this.database = database;
            this.inUse = false;
        }

        public int getId()        { return id; }
        public String getDatabase(){ return database; }
        public boolean isInUse()  { return inUse; }
        public void setInUse(boolean inUse) { this.inUse = inUse; }
    }
    """)

# ─── 17. database/DatabaseConnection.java ───
w("database/DatabaseConnection.java", """\
    package database;

    import util.Logger;
    import java.util.Collections;
    import java.util.List;
    import java.util.Map;

    /**
     * Represents a single database connection with query execution support.
     */
    public class DatabaseConnection {
        private static final Logger log = Logger.getLogger("database.connection");

        private final String host;
        private final int port;
        private final String database;
        private final String user;
        private final ConnectionPool pool;

        public DatabaseConnection(String host, int port, String database, String user) {
            log.info("Creating database connection: %s@%s:%d/%s", user, host, port, database);
            this.host = host;
            this.port = port;
            this.database = database;
            this.user = user;
            this.pool = new ConnectionPool(10);
            log.info("Database connection established");
        }

        /**
         * Execute a query and return results.
         *
         * @throws RuntimeException if no connection is available
         */
        public List<Map<String, Object>> executeQuery(String query, Object... params) {
            log.info("Executing query: %s", query);
            ConnectionHandle handle = pool.getConnection();
            try {
                log.debug("Query executed on connection #%d", handle.getId());
                return Collections.emptyList();
            } finally {
                pool.releaseConnection(handle);
            }
        }

        /**
         * Find a single record by ID.
         */
        public Map<String, Object> findById(String table, String id) {
            log.info("FindById: table=%s, id=%s", table, id);
            List<Map<String, Object>> results = executeQuery(
                    "SELECT * FROM " + table + " WHERE id = ?", id);
            if (results.isEmpty()) {
                log.warn("No record found: table=%s, id=%s", table, id);
                return null;
            }
            return results.get(0);
        }

        /**
         * Insert a new record.
         */
        public String insert(String table, Map<String, Object> data) {
            log.info("Insert into table: %s", table);
            executeQuery("INSERT INTO " + table + " VALUES (?)", data);
            String id = "generated_id";
            log.info("Inserted record with id: %s", id);
            return id;
        }

        /**
         * Update an existing record.
         */
        public void update(String table, String id, Map<String, Object> data) {
            log.info("Update: table=%s, id=%s", table, id);
            executeQuery("UPDATE " + table + " SET ? WHERE id = ?", data, id);
            log.info("Updated record: %s", id);
        }

        /**
         * Delete a record.
         */
        public void delete(String table, String id) {
            log.info("Delete: table=%s, id=%s", table, id);
            executeQuery("DELETE FROM " + table + " WHERE id = ?", id);
            log.info("Deleted record: %s", id);
        }

        public ConnectionPool getPool() { return pool; }
    }
    """)

# ─── 18. database/UserQueries.java ───
w("database/UserQueries.java", """\
    package database;

    import util.Logger;
    import java.util.List;
    import java.util.Map;

    /**
     * Database operations for the users table.
     */
    public class UserQueries {
        private static final Logger log = Logger.getLogger("database.queries.user");
        private final DatabaseConnection db;

        public UserQueries(DatabaseConnection db) {
            this.db = db;
        }

        public Map<String, Object> findByEmail(String email) {
            log.info("Finding user by email: %s", email);
            List<Map<String, Object>> results =
                    db.executeQuery("SELECT * FROM users WHERE email = ?", email);
            return results.isEmpty() ? null : results.get(0);
        }

        public List<Map<String, Object>> findActive() {
            log.info("Finding active users");
            return db.executeQuery("SELECT * FROM users WHERE active = true");
        }
    }
    """)

# ─── 19. database/SessionQueries.java ───
w("database/SessionQueries.java", """\
    package database;

    import util.Logger;
    import java.util.List;
    import java.util.Map;

    /**
     * Database operations for the sessions table.
     */
    public class SessionQueries {
        private static final Logger log = Logger.getLogger("database.queries.session");
        private final DatabaseConnection db;

        public SessionQueries(DatabaseConnection db) {
            this.db = db;
        }

        public List<Map<String, Object>> findByUserId(String userId) {
            log.info("Finding sessions for user: %s", userId);
            return db.executeQuery("SELECT * FROM sessions WHERE user_id = ?", userId);
        }

        public void invalidateAll(String userId) {
            log.info("Invalidating all sessions for user: %s", userId);
            db.executeQuery("DELETE FROM sessions WHERE user_id = ?", userId);
        }
    }
    """)

# ─── 20. models/UserRole.java ───
w("models/UserRole.java", """\
    package models;

    import util.Logger;

    /**
     * Represents the role of a user in the system.
     */
    public enum UserRole {
        GUEST, USER, MODERATOR, ADMIN, SUPER_ADMIN;

        private static final Logger log = Logger.getLogger("models.user_role");

        public String display() {
            switch (this) {
                case GUEST:      return "guest";
                case USER:       return "user";
                case MODERATOR:  return "moderator";
                case ADMIN:      return "admin";
                case SUPER_ADMIN:return "super_admin";
                default:
                    log.warn("Unknown role: %s", this);
                    return "unknown";
            }
        }
    }
    """)

# ─── 21. models/UserModel.java ───
w("models/UserModel.java", """\
    package models;

    import util.Logger;
    import java.util.ArrayList;
    import java.util.HashMap;
    import java.util.List;
    import java.util.Map;

    /**
     * Domain model representing a user in the application.
     */
    public class UserModel {
        private static final Logger log = Logger.getLogger("models.user");

        private String id;
        private String email;
        private String name;
        private String password;
        private UserRole role;
        private boolean active;
        private final Map<String, Object> metadata;

        public UserModel(String email, String name, String password) {
            log.info("Creating new user: %s", email);
            this.id = "usr_" + email;
            this.email = email;
            this.name = name;
            this.password = password;
            this.role = UserRole.USER;
            this.active = true;
            this.metadata = new HashMap<>();
        }

        /**
         * Validate that the user has valid field values.
         */
        public List<String> validate() {
            log.debug("Validating user: %s", email);
            List<String> errors = new ArrayList<>();
            if (email == null || email.isEmpty()) errors.add("email is required");
            if (name == null || name.isEmpty()) errors.add("name is required");
            if (password == null || password.length() < 8)
                errors.add("password must be at least 8 characters");
            if (!errors.isEmpty()) log.warn("User validation failed: %d errors", errors.size());
            return errors;
        }

        public boolean isAdmin() {
            return role == UserRole.ADMIN || role == UserRole.SUPER_ADMIN;
        }

        public void deactivate() {
            log.info("Deactivating user: %s", email);
            this.active = false;
        }

        public void setMetadata(String key, Object value) {
            metadata.put(key, value);
        }

        public String getId()       { return id; }
        public String getEmail()    { return email; }
        public String getName()     { return name; }
        public String getPassword() { return password; }
        public UserRole getRole()   { return role; }
        public boolean isActive()   { return active; }
    }
    """)

# ─── 22. models/SessionModel.java ───
w("models/SessionModel.java", """\
    package models;

    import util.Logger;

    /**
     * Represents an active user session.
     */
    public class SessionModel {
        private static final Logger log = Logger.getLogger("models.session");

        public enum Status { ACTIVE, EXPIRED, REVOKED, SUSPENDED }

        private final String id;
        private final String userId;
        private final String token;
        private Status status;
        private final String ipAddress;
        private final String userAgent;

        public SessionModel(String userId, String token, String ip, String userAgent) {
            log.info("Creating new session for user: %s", userId);
            this.id = "sess_" + userId;
            this.userId = userId;
            this.token = token;
            this.status = Status.ACTIVE;
            this.ipAddress = ip;
            this.userAgent = userAgent;
        }

        public boolean isValid() {
            log.debug("Checking session validity: %s", id);
            return status == Status.ACTIVE;
        }

        public void expire() {
            log.info("Expiring session: %s", id);
            this.status = Status.EXPIRED;
        }

        public void revoke() {
            log.info("Revoking session: %s", id);
            this.status = Status.REVOKED;
        }

        public void suspend() {
            log.info("Suspending session: %s", id);
            this.status = Status.SUSPENDED;
        }

        public String getId()       { return id; }
        public String getUserId()   { return userId; }
        public String getToken()    { return token; }
        public Status getStatus()   { return status; }
        public String getIpAddress(){ return ipAddress; }
    }
    """)

# ─── 23. models/PaymentModel.java ───
w("models/PaymentModel.java", """\
    package models;

    import errors.PaymentException;
    import util.Logger;
    import java.util.HashMap;
    import java.util.ArrayList;
    import java.util.List;
    import java.util.Map;

    /**
     * Domain model representing a financial transaction.
     */
    public class PaymentModel {
        private static final Logger log = Logger.getLogger("models.payment");

        public enum Status { PENDING, PROCESSING, COMPLETED, FAILED, REFUNDED, CANCELLED }

        private final String id;
        private final String userId;
        private final double amount;
        private final String currency;
        private Status status;
        private String transactionId;
        private final String description;
        private final Map<String, Object> metadata;

        public PaymentModel(String userId, double amount, String currency, String description) {
            log.info("Creating payment: user=%s, amount=%.2f %s", userId, amount, currency);
            this.id = "pay_" + userId;
            this.userId = userId;
            this.amount = amount;
            this.currency = currency;
            this.status = Status.PENDING;
            this.description = description;
            this.metadata = new HashMap<>();
        }

        /**
         * Validate payment fields.
         */
        public List<String> validate() {
            log.debug("Validating payment: %s", id);
            List<String> errors = new ArrayList<>();
            if (amount <= 0) errors.add("amount must be positive");
            if (currency == null || currency.isEmpty()) errors.add("currency is required");
            if (userId == null || userId.isEmpty()) errors.add("user ID is required");
            if (!errors.isEmpty()) log.warn("Payment validation failed: %d errors", errors.size());
            return errors;
        }

        /**
         * Transition payment to processing state.
         *
         * @throws PaymentException if not in PENDING state
         */
        public void process() throws PaymentException {
            log.info("Processing payment: %s", id);
            if (status != Status.PENDING) {
                throw new PaymentException(id, "Cannot process payment in " + status + " state");
            }
            this.status = Status.PROCESSING;
        }

        public void complete(String txnId) {
            log.info("Completing payment: %s, txn=%s", id, txnId);
            this.status = Status.COMPLETED;
            this.transactionId = txnId;
        }

        public void fail(String reason) {
            log.error("Payment failed: %s, reason=%s", id, reason);
            this.status = Status.FAILED;
            this.metadata.put("failure_reason", reason);
        }

        /**
         * Refund a completed payment.
         *
         * @throws PaymentException if not in COMPLETED state
         */
        public void refund() throws PaymentException {
            log.info("Refunding payment: %s", id);
            if (status != Status.COMPLETED) {
                throw new PaymentException(id, "Cannot refund payment in " + status + " state");
            }
            this.status = Status.REFUNDED;
        }

        public String getId()            { return id; }
        public String getUserId()        { return userId; }
        public double getAmount()        { return amount; }
        public String getCurrency()      { return currency; }
        public Status getStatus()        { return status; }
        public String getTransactionId() { return transactionId; }
    }
    """)

# ─── 24. services/BaseService.java ───
w("services/BaseService.java", """\
    package services;

    import util.Logger;

    /**
     * Common base for all application services.
     */
    public abstract class BaseService {
        private static final Logger log = Logger.getLogger("services.base");

        private final String serviceName;
        private final String serviceVersion;
        private boolean initialized;

        protected BaseService(String serviceName, String serviceVersion) {
            this.serviceName = serviceName;
            this.serviceVersion = serviceVersion;
            this.initialized = false;
        }

        public String getName() { return serviceName; }

        public void initialize() {
            log.info("Initializing service: %s v%s", serviceName, serviceVersion);
            this.initialized = true;
        }

        public void shutdown() {
            log.info("Shutting down service: %s", serviceName);
            this.initialized = false;
        }

        protected void requireInitialized() {
            if (!initialized) {
                throw new IllegalStateException(serviceName + " is not initialized");
            }
        }

        public boolean isInitialized() { return initialized; }
    }
    """)

# ─── 25. services/AuthenticationService.java ───
w("services/AuthenticationService.java", """\
    package services;

    import auth.AuthService;
    import auth.TokenService;
    import auth.User;
    import database.DatabaseConnection;
    import errors.AuthenticationException;
    import errors.TokenException;
    import util.Logger;
    import java.util.HashMap;
    import java.util.Map;

    /**
     * Orchestrates the full authentication workflow.
     *
     * Deep call chain entry point:
     * authenticate() -> login() -> generateToken() -> executeQuery() -> getConnection()
     */
    public class AuthenticationService extends BaseService {
        private static final Logger log = Logger.getLogger("services.authentication");

        private final AuthService authService;
        private final DatabaseConnection db;

        public AuthenticationService(DatabaseConnection db) {
            super("authentication", "1.0");
            log.info("Creating AuthenticationService");
            this.authService = new AuthService(new TokenService());
            this.db = db;
        }

        /**
         * Perform the full authentication flow.
         *
         * @throws AuthenticationException if credentials are invalid
         */
        public String authenticate(String email, String password)
                throws AuthenticationException {
            requireInitialized();
            log.info("Authenticating user: %s", email);

            // Step 1: login via AuthService -> TokenService.generateToken
            String token = authService.login(email, password);

            // Step 2: persist session -> DatabaseConnection.executeQuery -> ConnectionPool.getConnection
            Map<String, Object> session = new HashMap<>();
            session.put("token", token);
            session.put("email", email);
            db.insert("sessions", session);

            log.info("Authentication successful for: %s", email);
            return token;
        }

        public void logout(String token) throws TokenException {
            log.info("Logging out");
            authService.logout(token);
        }

        public User getCurrentUser(String token) throws TokenException {
            log.info("Getting current user");
            return authService.getCurrentUser(token);
        }
    }
    """)

# ─── 26. services/UserService.java ───
w("services/UserService.java", """\
    package services;

    import database.DatabaseConnection;
    import errors.ValidationException;
    import models.UserModel;
    import util.Logger;
    import java.util.HashMap;
    import java.util.List;
    import java.util.Map;

    /**
     * Manages user CRUD operations.
     */
    public class UserService extends BaseService {
        private static final Logger log = Logger.getLogger("services.user");
        private final DatabaseConnection db;

        public UserService(DatabaseConnection db) {
            super("user", "1.0");
            log.info("Creating UserService");
            this.db = db;
        }

        public UserModel create(String email, String name, String password)
                throws ValidationException {
            log.info("Creating user: %s", email);
            UserModel user = new UserModel(email, name, password);
            List<String> errors = user.validate();
            if (!errors.isEmpty()) {
                log.warn("User validation failed: %s", errors);
                throw new ValidationException("user", errors.toString());
            }
            Map<String, Object> data = new HashMap<>();
            data.put("email", email);
            data.put("name", name);
            db.insert("users", data);
            log.info("User created: %s", email);
            return user;
        }

        public UserModel findById(String id) {
            log.info("Finding user by ID: %s", id);
            db.findById("users", id);
            return new UserModel(id, id, "");
        }

        public void update(String id, Map<String, Object> data) {
            log.info("Updating user: %s", id);
            db.update("users", id, data);
        }

        public void delete(String id) {
            log.info("Deleting user: %s", id);
            db.delete("users", id);
        }

        public void deactivate(String id) {
            log.info("Deactivating user: %s", id);
            Map<String, Object> data = new HashMap<>();
            data.put("active", false);
            db.update("users", id, data);
        }
    }
    """)

# ─── 27. services/SessionService.java ───
w("services/SessionService.java", """\
    package services;

    import database.DatabaseConnection;
    import models.SessionModel;
    import util.Logger;
    import java.util.HashMap;
    import java.util.Map;

    /**
     * Manages user session lifecycle.
     */
    public class SessionService extends BaseService {
        private static final Logger log = Logger.getLogger("services.session");
        private final DatabaseConnection db;

        public SessionService(DatabaseConnection db) {
            super("session", "1.0");
            log.info("Creating SessionService");
            this.db = db;
        }

        public SessionModel create(String userId, String token, String ip, String userAgent) {
            log.info("Creating session for user: %s", userId);
            SessionModel session = new SessionModel(userId, token, ip, userAgent);
            Map<String, Object> data = new HashMap<>();
            data.put("user_id", userId);
            data.put("token", token);
            db.insert("sessions", data);
            return session;
        }

        public void invalidate(String sessionId) {
            log.info("Invalidating session: %s", sessionId);
            db.delete("sessions", sessionId);
        }

        public void invalidateAll(String userId) {
            log.info("Invalidating all sessions for user: %s", userId);
            db.executeQuery("DELETE FROM sessions WHERE user_id = ?", userId);
        }

        public SessionModel findByToken(String token) {
            log.info("Finding session by token");
            db.executeQuery("SELECT * FROM sessions WHERE token = ?", token);
            return null;
        }
    }
    """)

# ─── 28. services/payment/PaymentGateway.java ───
w("services/payment/PaymentGateway.java", """\
    package services.payment;

    import errors.PaymentException;
    import util.Logger;

    /**
     * Abstracts integration with an external payment gateway.
     */
    public class PaymentGateway {
        private static final Logger log = Logger.getLogger("services.payment.gateway");

        private final String provider;
        private int requestCount;

        public PaymentGateway(String provider) {
            this.provider = provider;
            this.requestCount = 0;
            log.info("Gateway initialized: provider=%s", provider);
        }

        /**
         * Submit a charge to the gateway.
         *
         * @throws PaymentException if the charge fails
         */
        public String charge(double amount, String currency) throws PaymentException {
            log.info("Charging %.2f %s via %s", amount, currency, provider);
            requestCount++;
            if (amount > 10000) {
                throw new PaymentException("txn_none", "Amount exceeds gateway limit");
            }
            String txnId = "txn_" + System.currentTimeMillis();
            log.info("Charge successful: %s", txnId);
            return txnId;
        }

        /**
         * Refund a previous charge.
         *
         * @throws PaymentException if the refund fails
         */
        public String refund(String chargeId) throws PaymentException {
            log.info("Refunding charge: %s", chargeId);
            requestCount++;
            String txnId = "ref_" + chargeId;
            log.info("Refund successful: %s", txnId);
            return txnId;
        }

        public int getRequestCount() { return requestCount; }
    }
    """)

# ─── 29. services/payment/PaymentProcessor.java ───
w("services/payment/PaymentProcessor.java", """\
    package services.payment;

    import database.DatabaseConnection;
    import errors.PaymentException;
    import errors.ValidationException;
    import models.PaymentModel;
    import services.BaseService;
    import util.Logger;
    import java.util.HashMap;
    import java.util.Map;

    /**
     * Handles the full payment processing lifecycle.
     */
    public class PaymentProcessor extends BaseService {
        private static final Logger log = Logger.getLogger("services.payment.processor");

        private final DatabaseConnection db;
        private final PaymentGateway gateway;

        public PaymentProcessor(DatabaseConnection db) {
            super("payment_processor", "1.0");
            log.info("Creating PaymentProcessor");
            this.db = db;
            this.gateway = new PaymentGateway("stripe");
        }

        /**
         * Process a payment end-to-end.
         *
         * @throws ValidationException if payment data is invalid
         * @throws PaymentException    if the gateway charge fails
         */
        public PaymentModel process(String userId, double amount, String currency)
                throws ValidationException, PaymentException {
            requireInitialized();
            log.info("Processing payment: user=%s, amount=%.2f %s", userId, amount, currency);

            PaymentModel payment = new PaymentModel(userId, amount, currency, "charge");
            java.util.List<String> errors = payment.validate();
            if (!errors.isEmpty()) {
                throw new ValidationException("payment", errors.toString());
            }

            payment.process();
            String txnId = gateway.charge(amount, currency);
            payment.complete(txnId);

            Map<String, Object> data = new HashMap<>();
            data.put("id", payment.getId());
            data.put("amount", amount);
            data.put("txn_id", txnId);
            db.insert("payments", data);

            log.info("Payment completed: %s", txnId);
            return payment;
        }

        /**
         * Refund a completed payment.
         *
         * @throws PaymentException if refund fails
         */
        public void refund(PaymentModel payment) throws PaymentException {
            log.info("Refunding payment: %s", payment.getId());
            gateway.refund(payment.getTransactionId());
            payment.refund();
            Map<String, Object> data = new HashMap<>();
            data.put("status", "refunded");
            db.update("payments", payment.getId(), data);
        }
    }
    """)

# ─── 30. routes/AuthRoutes.java ───
w("routes/AuthRoutes.java", """\
    package routes;

    import database.DatabaseConnection;
    import errors.AuthenticationException;
    import errors.TokenException;
    import services.AuthenticationService;
    import util.Logger;
    import java.util.HashMap;
    import java.util.Map;

    /**
     * HTTP route handlers for authentication endpoints.
     */
    public class AuthRoutes {
        private static final Logger log = Logger.getLogger("routes.auth");

        private final AuthenticationService authService;

        public AuthRoutes(DatabaseConnection db) {
            this.authService = new AuthenticationService(db);
            this.authService.initialize();
        }

        /**
         * Handle POST /login — entry point for deep call chain.
         *
         * Call chain: handleLogin -> authenticate -> login -> generateToken
         *             -> executeQuery -> getConnection
         */
        public Map<String, Object> handleLogin(Map<String, Object> request)
                throws AuthenticationException {
            log.info("POST /login");
            String email = (String) request.get("email");
            String password = (String) request.get("password");

            String token = authService.authenticate(email, password);

            Map<String, Object> response = new HashMap<>();
            response.put("token", token);
            response.put("status", 200);
            log.info("Login successful: %s", email);
            return response;
        }

        public Map<String, Object> handleLogout(Map<String, Object> request)
                throws TokenException {
            log.info("POST /logout");
            String token = (String) request.get("token");
            authService.logout(token);
            Map<String, Object> response = new HashMap<>();
            response.put("status", 200);
            return response;
        }

        public Map<String, Object> handleRefresh(Map<String, Object> request)
                throws TokenException {
            log.info("POST /refresh");
            // handled by TokenService
            Map<String, Object> response = new HashMap<>();
            response.put("status", 200);
            return response;
        }
    }
    """)

# ─── 31. routes/UserRoutes.java ───
w("routes/UserRoutes.java", """\
    package routes;

    import database.DatabaseConnection;
    import errors.ValidationException;
    import models.UserModel;
    import services.UserService;
    import util.Logger;
    import java.util.HashMap;
    import java.util.Map;

    /**
     * HTTP route handlers for user management endpoints.
     */
    public class UserRoutes {
        private static final Logger log = Logger.getLogger("routes.user");
        private final UserService userService;

        public UserRoutes(DatabaseConnection db) {
            this.userService = new UserService(db);
        }

        public Map<String, Object> handleCreate(Map<String, Object> request)
                throws ValidationException {
            log.info("POST /users");
            String email    = (String) request.get("email");
            String name     = (String) request.get("name");
            String password = (String) request.get("password");
            UserModel user  = userService.create(email, name, password);
            Map<String, Object> resp = new HashMap<>();
            resp.put("id", user.getId());
            resp.put("status", 201);
            return resp;
        }

        public Map<String, Object> handleGet(Map<String, Object> request) {
            log.info("GET /users/:id");
            String id = (String) request.get("id");
            UserModel user = userService.findById(id);
            Map<String, Object> resp = new HashMap<>();
            resp.put("user", user);
            resp.put("status", 200);
            return resp;
        }

        public Map<String, Object> handleDelete(Map<String, Object> request) {
            log.info("DELETE /users/:id");
            String id = (String) request.get("id");
            userService.delete(id);
            Map<String, Object> resp = new HashMap<>();
            resp.put("status", 204);
            return resp;
        }
    }
    """)

# ─── 32. validators/CommonValidator.java ───
w("validators/CommonValidator.java", """\
    package validators;

    import errors.ValidationException;
    import util.Logger;
    import java.util.regex.Pattern;

    /**
     * Reusable validation utilities.
     */
    public class CommonValidator {
        private static final Logger log = Logger.getLogger("validators.common");
        private static final Pattern EMAIL_PATTERN =
                Pattern.compile("^[a-zA-Z0-9._%+\\\\-]+@[a-zA-Z0-9.\\\\-]+\\\\.[a-zA-Z]{2,}$");

        public static String validateEmail(String email) throws ValidationException {
            log.debug("Validating email");
            if (email == null || email.isBlank())
                throw new ValidationException("email", "Email is required");
            String clean = email.trim().toLowerCase();
            if (!EMAIL_PATTERN.matcher(clean).matches())
                throw new ValidationException("email", "Invalid email format: " + email);
            return clean;
        }

        public static String validateString(String value, String field,
                                            int minLen, int maxLen) throws ValidationException {
            if (value == null || value.isBlank())
                throw new ValidationException(field, field + " is required");
            String stripped = value.strip();
            if (stripped.length() < minLen)
                throw new ValidationException(field, field + " is too short");
            if (stripped.length() > maxLen)
                throw new ValidationException(field, field + " is too long");
            return stripped;
        }

        public static double validatePositiveNumber(double value, String field)
                throws ValidationException {
            if (value <= 0)
                throw new ValidationException(field, field + " must be positive");
            return value;
        }
    }
    """)

# ─── 33. validators/UserValidator.java ───
w("validators/UserValidator.java", """\
    package validators;

    import errors.ValidationException;
    import util.Logger;
    import java.util.Map;

    /**
     * Validates user input for registration and updates.
     */
    public class UserValidator {
        private static final Logger log = Logger.getLogger("validators.user");

        /**
         * Validate user registration data.
         * Name collision: same method name as PaymentValidator.validate,
         * and route-level validate* helpers.
         */
        public static Map<String, Object> validate(Map<String, Object> data)
                throws ValidationException {
            log.info("Validating user data");
            String email = CommonValidator.validateEmail((String) data.get("email"));
            String name  = CommonValidator.validateString(
                    (String) data.get("name"), "name", 1, 100);
            data.put("email", email);
            data.put("name", name);
            return data;
        }

        public static Map<String, Object> validateLogin(Map<String, Object> data)
                throws ValidationException {
            log.info("Validating login data");
            String email    = CommonValidator.validateEmail((String) data.get("email"));
            String password = (String) data.get("password");
            if (password == null || password.isEmpty())
                throw new ValidationException("password", "Password is required");
            data.put("email", email);
            return data;
        }
    }
    """)

# ─── 34. validators/PaymentValidator.java ───
w("validators/PaymentValidator.java", """\
    package validators;

    import errors.ValidationException;
    import util.Logger;
    import java.util.Arrays;
    import java.util.List;
    import java.util.Map;

    /**
     * Validates payment input data.
     */
    public class PaymentValidator {
        private static final Logger log = Logger.getLogger("validators.payment");
        private static final List<String> SUPPORTED_CURRENCIES =
                Arrays.asList("USD", "EUR", "GBP", "JPY", "CAD");

        /**
         * Validate payment request data.
         * Name collision: same method name as UserValidator.validate.
         */
        public static Map<String, Object> validate(Map<String, Object> data)
                throws ValidationException {
            log.info("Validating payment data");
            double amount = CommonValidator.validatePositiveNumber(
                    (double) data.getOrDefault("amount", 0.0), "amount");
            String currency = (String) data.get("currency");
            if (!SUPPORTED_CURRENCIES.contains(currency))
                throw new ValidationException("currency", "Unsupported currency: " + currency);
            data.put("amount", amount);
            return data;
        }

        public static Map<String, Object> validateRefund(Map<String, Object> data)
                throws ValidationException {
            log.info("Validating refund data");
            if (!data.containsKey("transaction_id"))
                throw new ValidationException("transaction_id", "Transaction ID is required");
            return data;
        }
    }
    """)

# ─── 35. middleware/AuthMiddleware.java ───
w("middleware/AuthMiddleware.java", """\
    package middleware;

    import auth.TokenClaims;
    import auth.TokenService;
    import errors.AuthenticationException;
    import errors.TokenException;
    import util.Logger;
    import java.util.List;
    import java.util.Map;

    /**
     * Verifies authentication token on incoming requests.
     */
    public class AuthMiddleware {
        private static final Logger log = Logger.getLogger("middleware.auth");
        private static final List<String> PUBLIC_PATHS =
                java.util.Arrays.asList("/health", "/login", "/register");

        private final TokenService tokenService;

        public AuthMiddleware(TokenService tokenService) {
            this.tokenService = tokenService;
        }

        /**
         * Authenticate the request, attaching user claims to the context.
         *
         * @throws AuthenticationException if the token is missing or invalid
         */
        public Map<String, Object> authenticate(Map<String, Object> request)
                throws AuthenticationException {
            String path = (String) request.getOrDefault("path", "");
            if (PUBLIC_PATHS.contains(path)) return request;

            String authHeader = (String) request.getOrDefault("Authorization", "");
            String token = tokenService.extractToken(authHeader);
            if (token == null) {
                log.warn("No token on request to %s", path);
                throw new AuthenticationException("Missing authentication token");
            }

            try {
                TokenClaims claims = tokenService.validateToken(token);
                request.put("user", claims);
                log.info("Authenticated user: %s", claims.getUserId());
            } catch (TokenException e) {
                log.warn("Token validation failed: %s", e.getMessage());
                throw new AuthenticationException("Invalid or expired token");
            }

            return request;
        }
    }
    """)

# ─── 36. middleware/RateLimitMiddleware.java ───
w("middleware/RateLimitMiddleware.java", """\
    package middleware;

    import util.Logger;
    import java.util.HashMap;
    import java.util.Map;

    /**
     * Applies token-bucket rate limiting to incoming requests.
     */
    public class RateLimitMiddleware {
        private static final Logger log = Logger.getLogger("middleware.ratelimit");
        private static final int DEFAULT_LIMIT = 100;
        private static final int WINDOW_SECONDS = 60;

        private final Map<String, Integer> counters = new HashMap<>();

        public Map<String, Object> check(Map<String, Object> request) {
            String ip   = (String) request.getOrDefault("ip", "unknown");
            String path = (String) request.getOrDefault("path", "/");
            String key  = ip + ":" + path;

            int count = counters.getOrDefault(key, 0) + 1;
            counters.put(key, count);

            if (count > DEFAULT_LIMIT) {
                log.warn("Rate limit exceeded for %s", key);
                throw new IllegalStateException("Rate limit exceeded");
            }

            request.put("rateLimit", Map.of("remaining", DEFAULT_LIMIT - count));
            return request;
        }
    }
    """)

# ─── 37. api/v1/AuthController.java ───
w("api/v1/AuthController.java", """\
    package api.v1;

    import database.DatabaseConnection;
    import errors.AuthenticationException;
    import errors.ValidationException;
    import routes.AuthRoutes;
    import validators.UserValidator;
    import util.Logger;
    import java.util.Map;

    /**
     * API v1 authentication controller.
     */
    public class AuthController {
        private static final Logger log = Logger.getLogger("api.v1.auth");
        private final AuthRoutes routes;

        public AuthController(DatabaseConnection db) {
            this.routes = new AuthRoutes(db);
        }

        /**
         * POST /api/v1/auth/login
         * Name collision: same method name as api.v2.AuthController.handleLogin.
         */
        public Map<String, Object> handleLogin(Map<String, Object> request)
                throws AuthenticationException, ValidationException {
            log.info("API v1 handleLogin");
            UserValidator.validateLogin(request);
            return routes.handleLogin(request);
        }

        public Map<String, Object> handleLogout(Map<String, Object> request)
                throws Exception {
            log.info("API v1 handleLogout");
            return routes.handleLogout(request);
        }
    }
    """)

# ─── 38. api/v2/AuthController.java ───
w("api/v2/AuthController.java", """\
    package api.v2;

    import database.DatabaseConnection;
    import errors.AuthenticationException;
    import errors.ValidationException;
    import routes.AuthRoutes;
    import validators.UserValidator;
    import util.Logger;
    import java.util.Map;

    /**
     * API v2 authentication controller — adds MFA support.
     */
    public class AuthController {
        private static final Logger log = Logger.getLogger("api.v2.auth");
        private final AuthRoutes routes;

        public AuthController(DatabaseConnection db) {
            this.routes = new AuthRoutes(db);
        }

        /**
         * POST /api/v2/auth/login
         * Name collision: same method name as api.v1.AuthController.handleLogin.
         */
        public Map<String, Object> handleLogin(Map<String, Object> request)
                throws AuthenticationException, ValidationException {
            log.info("API v2 handleLogin");
            UserValidator.validateLogin(request);
            // V2 includes additional MFA step (stub)
            request.put("mfa_verified", true);
            return routes.handleLogin(request);
        }

        public Map<String, Object> handleLogout(Map<String, Object> request)
                throws Exception {
            log.info("API v2 handleLogout");
            return routes.handleLogout(request);
        }
    }
    """)

# ─── 39. tasks/CleanupTask.java ───
w("tasks/CleanupTask.java", """\
    package tasks;

    import database.DatabaseConnection;
    import util.Logger;

    /**
     * Background task that removes expired sessions and stale data.
     */
    public class CleanupTask {
        private static final Logger log = Logger.getLogger("tasks.cleanup");
        private final DatabaseConnection db;

        public CleanupTask(DatabaseConnection db) {
            this.db = db;
        }

        /**
         * Run the cleanup pass.
         */
        public int run() {
            log.info("Running cleanup task");
            int count = cleanExpiredSessions() + cleanOldPayments();
            log.info("Cleanup complete: %d records removed", count);
            return count;
        }

        private int cleanExpiredSessions() {
            log.info("Cleaning expired sessions");
            db.executeQuery("DELETE FROM sessions WHERE expires_at < NOW()");
            return 0;
        }

        private int cleanOldPayments() {
            log.info("Cleaning old failed payments");
            db.executeQuery("DELETE FROM payments WHERE status = 'failed' AND created_at < ?",
                    "30_days_ago");
            return 0;
        }
    }
    """)

# ─── 40. tasks/EmailTask.java ───
w("tasks/EmailTask.java", """\
    package tasks;

    import database.DatabaseConnection;
    import util.Logger;
    import java.util.List;
    import java.util.Map;

    /**
     * Background task that processes the outbound email queue.
     */
    public class EmailTask {
        private static final Logger log = Logger.getLogger("tasks.email");
        private final DatabaseConnection db;

        public EmailTask(DatabaseConnection db) {
            this.db = db;
        }

        public int run() {
            log.info("Processing email queue");
            List<Map<String, Object>> pending = db.executeQuery(
                    "SELECT * FROM email_queue WHERE status = 'pending' LIMIT 100");
            int sent = 0;
            for (Map<String, Object> email : pending) {
                if (sendEmail(email)) {
                    db.update("email_queue", (String) email.get("id"),
                            Map.of("status", "sent"));
                    sent++;
                }
            }
            log.info("Email task complete: %d sent", sent);
            return sent;
        }

        private boolean sendEmail(Map<String, Object> email) {
            log.debug("Sending email to %s", email.get("to"));
            return true;
        }
    }
    """)

# ─── 41. Main.java ───
w("Main.java", """\
    import database.DatabaseConnection;
    import routes.AuthRoutes;
    import routes.UserRoutes;
    import services.AuthenticationService;
    import services.SessionService;
    import services.UserService;
    import services.payment.PaymentProcessor;
    import tasks.CleanupTask;
    import tasks.EmailTask;
    import util.Logger;

    /**
     * Application entry point.
     */
    public class Main {
        private static final Logger log = Logger.getLogger("main");

        public static void main(String[] args) {
            log.info("Starting webapp");

            DatabaseConnection db = new DatabaseConnection(
                    "localhost", 5432, "webapp", "app_user");

            AuthenticationService authSvc = new AuthenticationService(db);
            authSvc.initialize();

            UserService userSvc = new UserService(db);
            userSvc.initialize();

            SessionService sessionSvc = new SessionService(db);
            sessionSvc.initialize();

            PaymentProcessor paymentProc = new PaymentProcessor(db);
            paymentProc.initialize();

            AuthRoutes authRoutes = new AuthRoutes(db);
            UserRoutes userRoutes = new UserRoutes(db);

            CleanupTask cleanupTask = new CleanupTask(db);
            EmailTask emailTask = new EmailTask(db);

            log.info("All services initialized");
        }
    }
    """)

print("Done! webapp_java fixture created.")
