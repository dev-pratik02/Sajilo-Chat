def validate_auth_payload(data):
    if not data:
        return False, "Missing JSON body"

    if "username" not in data or "password" not in data:
        return False, "username and password required"

    if len(data["password"]) < 8:
        return False, "Password too short"

    return True, None
