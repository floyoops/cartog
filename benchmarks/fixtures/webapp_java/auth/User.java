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
