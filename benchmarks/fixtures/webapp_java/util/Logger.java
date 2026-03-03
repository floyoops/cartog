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
