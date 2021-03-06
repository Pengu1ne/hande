#!/usr/bin/env python
'''Extract the momentum space correlation functions from analysed DMQMC data'''

import pandas as pd
import numpy as np
import sys
import argparse
import os
import pkgutil

_script_dir = os.path.dirname(os.path.abspath(__file__))
if not pkgutil.find_loader('pyhande'):
    sys.path.append(os.path.join(_script_dir, '../pyhande'))

import pyhande

def parse_args(args):
    '''Parse command-line arguments.

Parameters
----------
args : list of strings
    command-line arguments.

Returns
-------
options : :class:`ArgumentParser`
    Options read in from command line.
'''
    parser = argparse.ArgumentParser(usage=__doc__)
    parser.add_argument('-b', '--beta-val', action='store', required=True,
                        type=float, dest='beta', help='Inverse temperature '
                        'to extract the mometnum distribution at.')
    parser.add_argument('filename', nargs='+', help='Analysed DMQMC data. '
                        'i.e. the output of running finite_temp_analysis.py '
                        'on a HANDE calculation.')

    options = parser.parse_args(args)

    if not options.filename:
        parser.print_help()
        sys.exit(1)

    return options


def main(args):

    options = parse_args(args)
    data = pd.read_csv(options.filename[0],
                       sep=r'\s+')

    full = pyhande.dmqmc.extract_momentum_correlation_function(data, options.beta)

    print (full.to_string(index=False))

if __name__ == '__main__':

    main(sys.argv[1:])
