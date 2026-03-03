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
