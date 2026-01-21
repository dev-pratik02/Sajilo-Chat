from flask import Flask
from .config import Config
from .extensions import db, jwt, migrate
from .auth.routes import auth_bp

def create_app():
    app = Flask(__name__)
    app.config.from_object(Config)

    db.init_app(app)
    jwt.init_app(app)
    migrate.init_app(app, db)

    app.register_blueprint(auth_bp, url_prefix="/auth")

    return app
