from flask import Blueprint, request, jsonify
from flask_jwt_extended import create_access_token
from sqlalchemy.exc import IntegrityError

from ..extensions import db
from ..models import User
from ..utils.security import hash_password, verify_password
from .schemas import validate_auth_payload

auth_bp = Blueprint("auth", __name__)

@auth_bp.route("/register", methods=["POST"])
def register():
    data = request.get_json()
    valid, error = validate_auth_payload(data)
    if not valid:
        return jsonify({"error": error}), 400

    user = User(
        username=data["username"],
        password_hash=hash_password(data["password"])
    )

    db.session.add(user)
    try:
        db.session.commit()
    except IntegrityError:
        db.session.rollback()
        return jsonify({"error": "Username already exists"}), 409

    return jsonify({"message": "User registered"}), 201


@auth_bp.route("/login", methods=["POST"])
def login():
    data = request.get_json()
    valid, error = validate_auth_payload(data)
    if not valid:
        return jsonify({"error": error}), 400

    user = User.query.filter_by(username=data["username"]).first()
    if not user or not verify_password(data["password"], user.password_hash):
        return jsonify({"error": "Invalid credentials"}), 401

    token = create_access_token(
        identity=user.username
    )

    return jsonify({"access_token": token}), 200
