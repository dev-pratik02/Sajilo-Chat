FOR SERVER INITIALIZATON(BOTH FLASK FOR AUTHENTICATION AND FLASK DB):

Switch to server directory:
--> cd server

If virtual environment is not yet made:                
--> python3 -m venv .venv(for macOS/Linux)
--> python -m venv .venv (for windows)

In VS Code:
Open command palette->Select interpreter-> Enter interpreter path->Enter the path to your venv file

In your virtual environment:
--> pip install -r requirements.txt                     #Download all the dependencies

--> python3 unified_server.py(for macOS/Linux)
--> python unified_server.py(for Windows)

In your server directory:
-->python3 dm_server.py(for macOS/Linux)
-->python dm_server.py(for Windows)

FOR CLIENT:
Run main.dart on your emulator
Connect to the IP of the server

...

