#!/usr/bin/env python3
"""One checked changelog source for bundled and GitHub release notes."""
import argparse,json,re
from pathlib import Path

def catalog(root):
    version=re.search(r'^version:\s*(\d+\.\d+\.\d+)\+\d+', (root/'pubspec.yaml').read_text(), re.M)[1]
    text=(root/'CHANGELOG.md').read_text(encoding='utf-8')
    sections=re.split(r'^## (\d+\.\d+\.\d+)\s*$',text,flags=re.M)
    releases=[{'version':sections[i],'changes':[line[2:].strip() for line in sections[i+1].splitlines() if line.startswith('- ')]} for i in range(1,len(sections),2)]
    if not releases or releases[0]['version']!=version or any(not r['changes'] for r in releases): raise ValueError('Current pubspec version must lead CHANGELOG.md with non-empty changes.')
    return {'current':version,'releases':releases}

def main():
    parser=argparse.ArgumentParser();parser.add_argument('--write',action='store_true');parser.add_argument('--output');args=parser.parse_args()
    root=Path(__file__).resolve().parents[1];data=catalog(root)
    asset=root/'assets/release-notes.json';encoded=json.dumps(data,ensure_ascii=False,indent=2)+'\n'
    if args.write: asset.parent.mkdir(exist_ok=True);asset.write_text(encoded,encoding='utf-8')
    elif not asset.exists() or asset.read_text(encoding='utf-8')!=encoded: raise ValueError('Run python3 tool/release-notes.py --write after updating the app version and changelog.')
    if args.output:
        Path(args.output).write_text("## What’s changed\n\n"+'\n'.join('- '+line for line in data['releases'][0]['changes'])+'\n',encoding='utf-8')
    print('Release notes match '+data['current'])
if __name__=='__main__':main()
