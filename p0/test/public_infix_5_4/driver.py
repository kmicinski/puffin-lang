#!/usr/bin/python3
#####################################################
#############  LEAVE CODE BELOW  ALONE  #############
# Include base directory into path
import os, sys
sys.path.append(os.path.abspath(os.path.join(os.path.dirname( __file__ ), '..', '..')))

# Import tester
from tester import failtest, passtest, assertequals, runcmd, preparefile, runcmdsafe
#############    END UNTOUCHABLE CODE   #############
#####################################################

###################################
# Write your testing script below #
###################################
python_bin = sys.executable
import pickle

# run test file
b_stdout, b_stderr, b_exitcode = runcmdsafe(f"cd ../..; racket test.rkt -j -m translate-infix -g goldens/infix-interp-5-4.gld -i input-streams/4.in infix-programs/5.infix")
print(b_stdout.decode('utf-8'))
