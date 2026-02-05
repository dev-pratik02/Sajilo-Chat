import os
from datetime import timedelta

class Config:
    """
    Application configuration class
    Loads settings from environment variables with sensible defaults
    """
    
    # Security
    SECRET_KEY = os.getenv("SECRET_KEY", "dev-secret-change-me")
    JWT_SECRET_KEY = os.getenv("JWT_SECRET_KEY", "jwt-dev-secret-change-me")
    
    # Database
    SQLALCHEMY_DATABASE_URI = os.getenv("DATABASE_URL", "sqlite:///unified.db")
    SQLALCHEMY_TRACK_MODIFICATIONS = False
    
    # JWT Configuration
    JWT_ACCESS_TOKEN_EXPIRES = timedelta(
        hours=int(os.getenv("JWT_EXPIRE_HOURS", "24"))
    )
    JWT_ALGORITHM = os.getenv("JWT_ALGORITHM", "HS256")
    
    # Server Configuration
    FLASK_PORT = int(os.getenv("FLASK_PORT", "5001"))
    FLASK_HOST = os.getenv("FLASK_HOST", "0.0.0.0")
    FLASK_ENV = os.getenv("FLASK_ENV", "development")
    
    CHAT_PORT = int(os.getenv("CHAT_PORT", "5050"))
    CHAT_HOST = os.getenv("CHAT_HOST", "0.0.0.0")
    
    # Message Limits
    MAX_MESSAGE_SIZE = int(os.getenv("MAX_MESSAGE_SIZE", "10240"))  # 10KB
    BUFFER_SIZE = int(os.getenv("BUFFER_SIZE", "4096"))  # 4KB
    FILE_TRANSFER_TIMEOUT = int(os.getenv("FILE_TRANSFER_TIMEOUT", "300"))  # 5 min
    
    # Logging
    LOG_LEVEL = os.getenv("LOG_LEVEL", "INFO")
    LOG_FILE = os.getenv("LOG_FILE", "sajilo_chat.log")
    
    # Database API
    DB_API_URL = os.getenv("DB_API_URL", "http://localhost:5001/api")
    DB_API_TIMEOUT = int(os.getenv("DB_API_TIMEOUT", "5"))
    
    # Rate Limiting
    RATE_LIMIT_ENABLED = os.getenv("RATE_LIMIT_ENABLED", "false").lower() == "true"
    RATE_LIMIT_PER_MINUTE = int(os.getenv("RATE_LIMIT_PER_MINUTE", "60"))
    RATE_LIMIT_PER_HOUR = int(os.getenv("RATE_LIMIT_PER_HOUR", "1000"))
    
    # CORS
    CORS_ENABLED = os.getenv("CORS_ENABLED", "false").lower() == "true"
    CORS_ORIGINS = os.getenv("CORS_ORIGINS", "").split(",") if os.getenv("CORS_ORIGINS") else []
    
    @classmethod
    def validate(cls):
        """Validate configuration and warn about security issues"""
        warnings = []
        
        # Check if using default secrets
        if cls.SECRET_KEY == "dev-secret-change-me":
            warnings.append("⚠️  WARNING: Using default SECRET_KEY")
        
        if cls.JWT_SECRET_KEY == "jwt-dev-secret-change-me":
            warnings.append("⚠️  WARNING: Using default JWT_SECRET_KEY")
        
        # Check environment
        if cls.FLASK_ENV == "production":
            if cls.SECRET_KEY.startswith("dev-") or cls.JWT_SECRET_KEY.startswith("jwt-dev-"):
                warnings.append("🔴 CRITICAL: Production mode with development secrets!")
        
        # Print warnings
        if warnings:
            print("\n" + "=" * 60)
            for warning in warnings:
                print(warning)
            print("=" * 60 + "\n")
        
        return len(warnings) == 0
    
    @classmethod
    def display(cls):
        """Display current configuration (excluding secrets)"""
        print("=" * 60)
        print("CURRENT CONFIGURATION")
        print("=" * 60)
        print(f"Environment: {cls.FLASK_ENV}")
        print(f"Flask Server: {cls.FLASK_HOST}:{cls.FLASK_PORT}")
        print(f"Chat Server: {cls.CHAT_HOST}:{cls.CHAT_PORT}")
        print(f"Database: {cls.SQLALCHEMY_DATABASE_URI}")
        print(f"JWT Expiry: {cls.JWT_ACCESS_TOKEN_EXPIRES}")
        print(f"Max Message Size: {cls.MAX_MESSAGE_SIZE} bytes")
        print(f"Buffer Size: {cls.BUFFER_SIZE} bytes")
        print(f"File Transfer Timeout: {cls.FILE_TRANSFER_TIMEOUT} seconds")
        print(f"Log Level: {cls.LOG_LEVEL}")
        print(f"Rate Limiting: {'Enabled' if cls.RATE_LIMIT_ENABLED else 'Disabled'}")
        print(f"CORS: {'Enabled' if cls.CORS_ENABLED else 'Disabled'}")
        print("=" * 60)


class DevelopmentConfig(Config):
    """Development-specific configuration"""
    DEBUG = True
    TESTING = False


class ProductionConfig(Config):
    """Production-specific configuration"""
    DEBUG = False
    TESTING = False
    
    @classmethod
    def validate(cls):
        """Additional production validation"""
        if not super().validate():
            raise ValueError("Invalid production configuration!")
        
        # Ensure production uses strong secrets
        if (cls.SECRET_KEY == "dev-secret-change-me" or 
            cls.JWT_SECRET_KEY == "jwt-dev-secret-change-me"):
            raise ValueError("Must set production secrets!")
        
        # Ensure using production-grade database
        if "sqlite" in cls.SQLALCHEMY_DATABASE_URI.lower():
            print("⚠️  WARNING: SQLite not recommended for production")
        
        return True


class TestingConfig(Config):
    """Testing-specific configuration"""
    TESTING = True
    SQLALCHEMY_DATABASE_URI = "sqlite:///:memory:"
    JWT_ACCESS_TOKEN_EXPIRES = timedelta(minutes=5)


# Configuration dictionary
config = {
    'development': DevelopmentConfig,
    'production': ProductionConfig,
    'testing': TestingConfig,
    'default': DevelopmentConfig
}


def get_config(env=None):
    """Get configuration based on environment"""
    if env is None:
        env = os.getenv('FLASK_ENV', 'development')
    return config.get(env, config['default'])
