The project is focused on developing a Metatrader 5 EA, a replica of my TradingView Strategy (see SourceCode.txt for full script). 

Go through line by line the SourceCode *Pinescript* , translate to MQL5 and port them one by one to form an MT5 EA. 

The core skeleton comprises of 2 EAs, one that will attached to the Prop MT5 account and will be triggering the trades and the other EA will be attached to the Hedge MT5 account and will open the opposite position. 

You can opt, with a valid reason, to use .mpq files i.e. for the dashboard or for the indicators.

Priority is to ensure parity with TV Strategy and that all ported features are fully functional. Dashboard (below) will be done at a later stage. <img width="513" alt="Screenshot 2025-05-17 at 10 36 05 AM" src="https://github.com/user-attachments/assets/f9df3bb5-1849-4f24-b89a-5b969fcc9f1a" />

IMPORTANT ----> Compile code using the workflow/action "Build & Package MQ5 EAs"

on:
  push:
    branches: [main, master]
  workflow_dispatch:         # manual trigger button

concurrency: build-ea-${{ github.ref }}

jobs:
  build:
    runs-on: [self-hosted, crossover, mt5]

    steps:
      - uses: actions/checkout@v4

      - name: Compile all MQ5 sources
        run: ./scripts/compile.sh

      - name: Upload compiled EAs
        uses: actions/upload-artifact@v4
        with:
          name: EA-binaries
          path: path:"**/*.ex5"        
          retention-days: 14          
          
          
Code that you deliver must be error/warning-free.
