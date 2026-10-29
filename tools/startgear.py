"""Starting equipment and skills per recruitable warrior, as data-server ids -> vm/startgear.json.

The game's own data defines them (Character/<Class>/<Class>.base: StartingEquipment / StartingSkill per BaseTypeDef);
the original data server handed them out on ADD_WARRIOR. Ids follow WEGameDataBase (WECharacterDBFile.cpp):
  warrior   0x01000000 | basetype << 12 | class      (gamedatabase.cfg [w:start]: "pangolin|7", "<basetype_type2|2>")
  equipment 0x05000000 | n << 12 | class            ([equipment:pangolin] "staff_staff5|5")
  skill     0x08000000 | n << 12 | class            ([skill:pangolin] "skill_poisondart|4")

usage: python -I tools/startgear.py ..\\we_extracted\\v4.000 vm\\startgear.json
Reads the extracted (read-only) game data; the output is game-derived, so it stays out of git.
"""
import json, os, re, sys


def read_text(path):
    raw = open(path, 'rb').read()
    return raw.decode('utf-16') if raw[:2] in (b'\xff\xfe', b'\xfe\xff') else raw.decode('latin-1')


def block(text, start, name):
    """Lines of the {...} block that follows `name` after offset `start` (one level, entries only)."""
    m = re.compile(r'\b%s\s*\{(.*?)\}' % re.escape(name), re.S).search(text, start)
    return [l.strip().strip('"') for l in m.group(1).splitlines() if l.strip() and not l.strip().startswith('//')] if m else []


def main(data, out):
    db = read_text(os.path.join(data, 'gamedatabase.cfg')).replace('\r', '')
    warriors = db[db.index('[w:start]'):db.index('[w:end')]
    sections = {}
    for kind, cls, body in re.findall(r'\[(equipment|skill):(\w+)\]\n(.*?)\n\{', db, re.S):
        sections[(kind, cls)] = {k: int(v) for k, v in re.findall(r'^(\w+)\|(\d+)$', body, re.M)}

    folders = {f.lower(): f for f in os.listdir(os.path.join(data, 'Character'))}
    result = {}
    for cls, cidx, body in re.findall(r'^(\w+)\|(\d+)\(\d+,\d+\)\n((?:\t.*\n?)*)', warriors, re.M):
        if cls not in folders:
            continue  # monsters/npcs listed as warriors (beholder, earthgolem) have no recruitable .base
        folder = folders[cls]
        base = read_text(os.path.join(data, 'Character', folder, folder + '.base'))
        for bt, bidx in re.findall(r'<(\w+)\|(\d+)>', body):
            m = re.search(r'BaseTypeDef\s*:\s*%s\b' % re.escape(bt), base, re.I)
            if not m:
                continue
            wid = 0x01000000 | int(bidx) << 12 | int(cidx)
            ids = {}
            for kind, key, tag in (('equipment', 'StartingEquipment', 0x05000000), ('skill', 'StartingSkill', 0x08000000)):
                table, ids[kind] = sections.get((kind, cls), {}), []
                for name in block(base, m.end(), key):
                    n = table.get(name.lower())
                    if n is None:
                        print('warning: %s %s %s not in gamedatabase.cfg' % (cls, kind, name))
                        continue
                    ids[kind].append(tag | n << 12 | int(cidx))
            result[str(wid)] = {'class': cls, 'basetype': bt, **ids}
    json.dump(result, open(out, 'w'), indent=1)
    print('%d warrior types -> %s' % (len(result), out))
    return result


if __name__ == '__main__':
    r = main(sys.argv[1], sys.argv[2])
    p = r['16785415']  # Ahiga's type: pangolin Tamer
    assert p['class'] == 'pangolin' and p['basetype'] == 'basetype_type2', p
    assert p['equipment'][0] == 0x05000000 | 5 << 12 | 7, hex(p['equipment'][0])   # STAFF_Staff5 = staff_staff5|5
    assert len(p['skill']) == 3, p['skill']
