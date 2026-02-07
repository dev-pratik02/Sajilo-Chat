#!/usr/bin/env python3
"""
Cross-Platform Server Starter for Sajilo Chat
Works on Windows, Mac, and Linux
"""

import os
import sys
import secrets
import subprocess
import platform

def print_header():
    """Print startup header"""
    print("=" * 60)
    print("    SAJILO CHAT SERVER STARTUP")
    print(f"    Platform: {platform.system()}")
    print("=" * 60)
    print()

def generate_secret():
    """Generate a secure JWT secret"""
    return secrets.token_urlsafe(32)

def check_dependencies():
    """Check if required Python packages are installed"""
    print("📦 Checking dependencies...")
    required = ['flask', 'flask_sqlalchemy', 'flask_jwt_extended', 'werkzeug']
    missing = []
    
    for package in required:
        try:
            __import__(package)
        except ImportError:
            missing.append(package)
    
    if missing:
        print(f"❌ Missing packages: {', '.join(missing)}")
        print("   Installing...")
        subprocess.check_call([
            sys.executable, '-m', 'pip', 'install',
            'flask', 'flask-sqlalchemy', 'flask-jwt-extended', 'werkzeug'
        ])
        print("✓ Packages installed")
    else:
        print("✓ All dependencies OK")
    print()

def setup_jwt_secret():
    """Setup JWT_SECRET environment variable"""
    if 'JWT_SECRET' in os.environ:
        print("✓ JWT_SECRET already set")
        print(f"   Value: {os.environ['JWT_SECRET'][:10]}...{os.environ['JWT_SECRET'][-10:]}")
        return os.environ['JWT_SECRET']
    
    print("🔐 JWT_SECRET not found, generating new one...")
    secret = generate_secret()
    os.environ['JWT_SECRET'] = secret
    
    print(f"✓ Generated: {secret[:10]}...{secret[-10:]}")
    print()
    print("⚠️  IMPORTANT: Save this secret for later use!")
    print()
    
    # Try to save to .env file
    env_file = '.env'
    if os.path.exists(env_file):
        print(f"   Found existing {env_file} file")
        response = input("   Overwrite with new secret? (y/N): ").strip().lower()
        if response != 'y':
            print("   Keeping existing .env file")
            print()
            return secret
    
    try:
        with open(env_file, 'w') as f:
            f.write(f'# Sajilo Chat Environment Variables\n')
            f.write(f'# Generated on {platform.system()} - {platform.node()}\n\n')
            f.write(f'JWT_SECRET={secret}\n')
        print(f"   ✓ Saved to {env_file}")
        print(f"   You can load this later with: export JWT_SECRET=$(cat .env | grep JWT_SECRET | cut -d= -f2)")
    except Exception as e:
        print(f"   ⚠️  Could not save to .env: {e}")
        print(f"   Please save manually: JWT_SECRET={secret}")
    
    print()
    return secret

def save_secret_instructions(secret):
    """Print instructions for saving the secret permanently"""
    system = platform.system()
    print("=" * 60)
    print("  TO SAVE THIS SECRET PERMANENTLY:")
    print("=" * 60)
    
    if system == "Darwin" or system == "Linux":  # Mac or Linux
        shell = os.environ.get('SHELL', '/bin/bash')
        if 'zsh' in shell:
            config_file = '~/.zshrc'
        else:
            config_file = '~/.bashrc'
        
        print(f"\n  For {system}:")
        print(f"  1. Run this command:")
        print(f'     echo \'export JWT_SECRET="{secret}"\' >> {config_file}')
        print(f"  2. Reload your shell:")
        print(f'     source {config_file}')
        
    elif system == "Windows":
        print("\n  For Windows:")
        print("  1. Search 'Environment Variables' in Windows")
        print("  2. Click 'Environment Variables' button")
        print("  3. Under 'User variables', click 'New'")
        print("  4. Variable name: JWT_SECRET")
        print(f"  5. Variable value: {secret}")
        print("  6. Click OK")
    
    print("\n  Or use the .env file (already created)")
    print("=" * 60)
    print()

def start_server():
    """Start the unified server"""
    print("🚀 Starting Unified Server (Flask API) on port 5001...")
    print("=" * 60)
    print()
    
    try:
        # Check if unified_server.py exists
        if not os.path.exists('unified_server.py'):
            print("❌ Error: unified_server.py not found in current directory")
            print("   Please run this script from the server directory")
            sys.exit(1)
        
        # Start the server
        subprocess.run([sys.executable, 'unified_server.py'])
        
    except KeyboardInterrupt:
        print("\n\n⚠️  Server stopped by user")
    except Exception as e:
        print(f"\n❌ Error starting server: {e}")
        sys.exit(1)

def main():
    """Main function"""
    print_header()
    
    # Setup dependencies
    check_dependencies()
    
    # Setup JWT secret
    secret = setup_jwt_secret()
    
    # Show save instructions
    if 'JWT_SECRET' not in os.environ or os.environ.get('JWT_SECRET') != secret:
        save_secret_instructions(secret)
    
    # Ask user if ready to start
    try:
        input("Press ENTER to start the server (Ctrl+C to cancel)...")
    except KeyboardInterrupt:
        print("\n\nCancelled by user")
        sys.exit(0)
    
    print()
    
    # Start server
    start_server()

if __name__ == '__main__':
    main()
