#!/usr/bin/env python3
import argparse
from ytmusicapi import YTMusic

parser = argparse.ArgumentParser(description="Configure YTMusicBar browser headers")
parser.add_argument("--file", required=True)
args = parser.parse_args()
print("Cole os headers de uma requisição autenticada /browse e pressione Enter:")
YTMusic.setup(filepath=args.file)
print(f"Credenciais salvas em {args.file}")
