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
