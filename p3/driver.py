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

# prepare necessary files
preparefile('../../test.rkt')
preparefile("testdata.cfg")

# run test file
runcmdsafe('rm ./output')
b_stdout, b_stderr, b_exitcode = runcmdsafe(f"cd ../..; racket test.rkt -m json {os.getcwd()}/testdata.cfg")
print(b_stdout.decode('ascii', errors='ignore'))
