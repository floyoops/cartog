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
