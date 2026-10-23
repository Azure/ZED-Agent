# SdsJsonLib.ps1 — position-aware reader/editor for ServiceDatacenterSettings-style JSON
# (CloudSettings / StampSettings / Resources / Properties). Edits change only the bytes of
# the touched values, so a PR diff shows exactly the preserved settings and nothing else.
# Dot-sourced by Invoke-RevertBits.ps1 and its tests.

if (-not ('ZedSds.SdsJson' -as [type])) {
    Add-Type -Language CSharp -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Text;
using System.Text.Json;

namespace ZedSds {
    public class Member {
        public string ObjectPath;   // path of the containing object (index form, e.g. /CloudSettings[2]/Resources[0]/Properties)
        public string Key;
        public int KeyStart;        // byte offset of the key's opening quote
        public int KeyEnd;          // reader position after the property name (may include the ':' separator)
        public int ValueStart;
        public int ValueEnd;        // exclusive
        public string Raw;          // raw UTF-8 text of the value
        public bool IsContainer;
        public int Index;           // position within the object
    }
    public class ObjInfo {
        public string Path;
        public int Open;            // offset of '{'
        public int Close;           // offset of '}'
        public List<Member> Members = new List<Member>();
    }
    public class ParseResult {
        public Dictionary<string, ObjInfo> Objects = new Dictionary<string, ObjInfo>();
        public List<Member> Members = new List<Member>();
        public Dictionary<string, string> Labels = new Dictionary<string, string>(); // "/A[3]" -> "/A[Id=x]"
    }

    public static class SdsJson {
        static readonly string[] IdentityKeys = new[] { "Id", "CloudName", "StampId", "Name", "name" };

        class Frame {
            public bool IsArray; public string Path; public int Index = -1;
            public string PendingKey; public int PendingKeyStart; public int PendingKeyEnd; public ObjInfo Obj;
            public int ContainerStart; public string ParentPath; public string KeyInParent; public int KeyStartInParent; public int KeyEndInParent;
        }

        static string Esc(string k) { return k.Replace("~", "~0").Replace("/", "~1"); }

        public static ParseResult Parse(byte[] bytes) {
            int start = (bytes.Length >= 3 && bytes[0] == 0xEF && bytes[1] == 0xBB && bytes[2] == 0xBF) ? 3 : 0;
            var span = new ReadOnlySpan<byte>(bytes, start, bytes.Length - start);
            var reader = new Utf8JsonReader(span, new JsonReaderOptions { CommentHandling = JsonCommentHandling.Skip, AllowTrailingCommas = true });
            var res = new ParseResult();
            var stack = new Stack<Frame>();
            while (reader.Read()) {
                int tStart = (int)reader.TokenStartIndex + start;
                int tEnd = (int)reader.BytesConsumed + start;
                switch (reader.TokenType) {
                    case JsonTokenType.PropertyName: {
                        var f = stack.Peek();
                        f.PendingKey = reader.GetString(); f.PendingKeyStart = tStart; f.PendingKeyEnd = tEnd;
                        break;
                    }
                    case JsonTokenType.StartObject:
                    case JsonTokenType.StartArray: {
                        string path; string parentPath = null; string key = null; int ks = -1, ke = -1;
                        if (stack.Count == 0) path = "";
                        else {
                            var p = stack.Peek(); parentPath = p.Path;
                            if (p.IsArray) { p.Index++; path = p.Path + "[" + p.Index + "]"; }
                            else { key = p.PendingKey; ks = p.PendingKeyStart; ke = p.PendingKeyEnd; path = p.Path + "/" + Esc(key); }
                        }
                        var nf = new Frame { IsArray = reader.TokenType == JsonTokenType.StartArray, Path = path, ContainerStart = tStart, ParentPath = parentPath, KeyInParent = key, KeyStartInParent = ks, KeyEndInParent = ke };
                        if (!nf.IsArray) { nf.Obj = new ObjInfo { Path = path, Open = tStart }; res.Objects[path] = nf.Obj; }
                        stack.Push(nf);
                        break;
                    }
                    case JsonTokenType.EndObject:
                    case JsonTokenType.EndArray: {
                        var f = stack.Pop();
                        if (f.Obj != null) f.Obj.Close = tStart;
                        if (stack.Count > 0 && f.KeyInParent != null) {
                            var p = stack.Peek();
                            AddMember(res, p, f.KeyInParent, f.KeyStartInParent, f.KeyEndInParent, f.ContainerStart, tEnd, bytes, true);
                        }
                        break;
                    }
                    default: {
                        if (stack.Count == 0) break;
                        var p = stack.Peek();
                        if (p.IsArray) { p.Index++; break; }
                        AddMember(res, p, p.PendingKey, p.PendingKeyStart, p.PendingKeyEnd, tStart, tEnd, bytes, false);
                        break;
                    }
                }
            }
            // Identity labels for array elements: /X[3] -> /X[Id=value]
            foreach (var m in res.Members) {
                if (m.IsContainer) continue;
                int i = m.ObjectPath.LastIndexOf('[');
                if (i < 0 || !m.ObjectPath.EndsWith("]")) continue;
                if (Array.IndexOf(IdentityKeys, m.Key) < 0) continue;
                if (res.Labels.ContainsKey(m.ObjectPath)) continue;
                string v = m.Raw.Length >= 2 && m.Raw[0] == '"' ? JsonSerializer.Deserialize<string>(m.Raw) : m.Raw;
                res.Labels[m.ObjectPath] = m.ObjectPath.Substring(0, i) + "[" + m.Key + "=" + v + "]";
            }
            return res;
        }

        static void AddMember(ParseResult res, Frame p, string key, int ks, int ke, int vs, int ve, byte[] bytes, bool container) {
            var m = new Member { ObjectPath = p.Path, Key = key, KeyStart = ks, KeyEnd = ke, ValueStart = vs, ValueEnd = ve,
                                 Raw = Encoding.UTF8.GetString(bytes, vs, ve - vs), IsContainer = container, Index = p.Obj.Members.Count };
            p.Obj.Members.Add(m); res.Members.Add(m);
        }

        // Replace index segments with identity labels, from the outermost segment inward.
        public static string Label(ParseResult r, string path) {
            var sb = new StringBuilder(); int pos = 0; string idx = "";
            while (pos < path.Length) {
                int b = path.IndexOf('[', pos);
                if (b < 0) { idx += path.Substring(pos); sb.Append(path.Substring(pos)); break; }
                int e = path.IndexOf(']', b);
                string segIdx = idx + path.Substring(pos, e + 1 - pos);
                string lab;
                if (r.Labels.TryGetValue(segIdx, out lab)) {
                    int lb = lab.LastIndexOf('[');
                    sb.Append(path.Substring(pos, b - pos)).Append(lab.Substring(lb));
                } else sb.Append(path.Substring(pos, e + 1 - pos));
                idx = segIdx; pos = e + 1;
            }
            return sb.ToString();
        }
    }
}
'@
}

# Settings = scalar or container members of every object whose path ends in '/Properties'.
# Returns hashtable "<labelledObjectPath>|<key>" -> [pscustomobject]@{ scope; key; raw; member; objectIndexPath }
function Get-SdsSettings([byte[]]$Bytes) {
    $r = [ZedSds.SdsJson]::Parse($Bytes)
    $out = @{}
    $labelCache = @{}
    foreach ($m in $r.Members) {
        if (-not $m.ObjectPath.EndsWith('/Properties')) { continue }
        if (-not $labelCache.ContainsKey($m.ObjectPath)) { $labelCache[$m.ObjectPath] = [ZedSds.SdsJson]::Label($r, $m.ObjectPath) }
        $scope = $labelCache[$m.ObjectPath]
        $out["$scope|$($m.Key)"] = [pscustomobject]@{ scope = $scope; key = $m.Key; raw = $m.Raw; member = $m; objectIndexPath = $m.ObjectPath }
    }
    return @{ parse = $r; settings = $out; scopeIndex = $labelCache }
}

# Throws if the bytes are not valid JSON (same reader options as the parser).
function Test-SdsJson([byte[]]$Bytes) {
    $null = [ZedSds.SdsJson]::Parse($Bytes)
}

function ConvertTo-CanonicalJson([string]$Raw) {
    try { return ([System.Text.Json.JsonDocument]::Parse($Raw).RootElement.GetRawText() -replace '\s+', '') } catch { return $Raw }
}

# Friendly scope: "Default", "Cloud Public", "Cloud Public / Stamp xyz" (+ resource id when not ServiceConfig).
function Format-SdsScope([string]$Scope) {
    $parts = @()
    if ($Scope -match '/CloudSettings\[CloudName=([^\]]+)\]') { $parts += "Cloud $($Matches[1])" }
    if ($Scope -match '/StampSettings\[StampId=([^\]]+)\]') { $parts += "Stamp $($Matches[1])" }
    if ($Scope -match '/(?:Resources|DefaultResources)\[Id=([^\]]+)\]/Properties$' -and $Matches[1] -ne 'ServiceConfig') { $parts += "Resource $($Matches[1])" }
    if ($parts.Count -eq 0) { return 'Default' }
    return ($parts -join ' / ')
}

# Diff two SDS files. Returns change objects: id, file, scope, scopeLabel, key, kind (modified|added|removed|scope-added|scope-removed), previous, current
function Compare-SdsSettings([byte[]]$Previous, [byte[]]$Current, [string]$File) {
    $p = Get-SdsSettings $Previous; $c = Get-SdsSettings $Current
    $pScopes = @{}; foreach ($v in $p.settings.Values) { $pScopes[$v.scope] = $true }
    $cScopes = @{}; foreach ($v in $c.settings.Values) { $cScopes[$v.scope] = $true }
    $changes = New-Object System.Collections.Generic.List[object]
    foreach ($k in $c.settings.Keys) {
        $cv = $c.settings[$k]
        if ($p.settings.ContainsKey($k)) {
            $pv = $p.settings[$k]
            if ((ConvertTo-CanonicalJson $pv.raw) -ne (ConvertTo-CanonicalJson $cv.raw)) {
                $changes.Add([pscustomobject]@{ file = $File; scope = $cv.scope; key = $cv.key; kind = 'modified'; previous = $pv.raw; current = $cv.raw })
            }
        } elseif ($pScopes.ContainsKey($cv.scope)) {
            $changes.Add([pscustomobject]@{ file = $File; scope = $cv.scope; key = $cv.key; kind = 'added'; previous = $null; current = $cv.raw })
        }
    }
    foreach ($k in $p.settings.Keys) {
        if ($c.settings.ContainsKey($k)) { continue }
        $pv = $p.settings[$k]
        if ($cScopes.ContainsKey($pv.scope)) {
            $changes.Add([pscustomobject]@{ file = $File; scope = $pv.scope; key = $pv.key; kind = 'removed'; previous = $pv.raw; current = $null })
        }
    }
    foreach ($s in $cScopes.Keys) { if (-not $pScopes.ContainsKey($s)) { $changes.Add([pscustomobject]@{ file = $File; scope = $s; key = $null; kind = 'scope-added'; previous = $null; current = $null }) } }
    foreach ($s in $pScopes.Keys) { if (-not $cScopes.ContainsKey($s)) { $changes.Add([pscustomobject]@{ file = $File; scope = $s; key = $null; kind = 'scope-removed'; previous = $null; current = $null }) } }
    foreach ($ch in $changes) {
        Add-Member -InputObject $ch -NotePropertyName scopeLabel -NotePropertyValue (Format-SdsScope $ch.scope)
        $sha = [System.Security.Cryptography.SHA1]::Create()
        $hash = [BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes("$($ch.file)|$($ch.scope)|$($ch.key)|$($ch.kind)"))).Replace('-', '').Substring(0, 8).ToLowerInvariant()
        Add-Member -InputObject $ch -NotePropertyName id -NotePropertyValue $hash
    }
    return @($changes | Sort-Object @{ Expression = { switch ($_.scopeLabel) { 'Default' { 0 } default { 1 } } } }, scopeLabel, key)
}

# Apply preserved changes (modified/added/removed) onto the PREVIOUS file bytes, taking values from
# CURRENT. Returns @{ bytes; applied[]; skipped[] }. Bytes outside the edited spans are untouched.
function Invoke-SdsPreserve([byte[]]$Previous, [byte[]]$Current, [object[]]$Changes) {
    $p = Get-SdsSettings $Previous; $c = Get-SdsSettings $Current
    $edits = New-Object System.Collections.Generic.List[object]   # @{ start; end; bytes }
    $applied = New-Object System.Collections.Generic.List[object]
    $skipped = New-Object System.Collections.Generic.List[object]
    $removeByObj = @{}
    foreach ($ch in $Changes) {
        $k = "$($ch.scope)|$($ch.key)"
        switch ($ch.kind) {
            'modified' {
                $pm = $p.settings[$k].member; $cm = $c.settings[$k].member
                $edits.Add(@{ start = $pm.ValueStart; end = $pm.ValueEnd; bytes = [Text.Encoding]::UTF8.GetBytes($cm.Raw) })
                $applied.Add($ch)
            }
            'added' {
                $objIdx = $null
                foreach ($kv in $p.scopeIndex.GetEnumerator()) { if ($kv.Value -eq $ch.scope) { $objIdx = $kv.Key; break } }
                $obj = if ($objIdx) { $p.parse.Objects[$objIdx] } else { $null }
                if (-not $obj -or $obj.Members.Count -eq 0) { $skipped.Add([pscustomobject]@{ change = $ch; reason = 'scope has no existing settings to anchor the insert' }); continue }
                $last = $obj.Members[$obj.Members.Count - 1]
                $lineStart = $last.KeyStart
                while ($lineStart -gt 0 -and $Previous[$lineStart - 1] -ne 10) { $lineStart-- }
                $indent = [Text.Encoding]::UTF8.GetString($Previous, $lineStart, $last.KeyStart - $lineStart)
                if ($indent -match '\S') { $indent = ' ' * $indent.Length }
                $nl = if ($lineStart -ge 2 -and $Previous[$lineStart - 2] -eq 13) { "`r`n" } else { "`n" }
                $cm = $c.settings[$k].member
                $q = $cm.KeyStart + 1
                while ($q -lt $Current.Length -and $Current[$q] -ne 34) { if ($Current[$q] -eq 92) { $q++ }; $q++ }
                $keyRaw = [Text.Encoding]::UTF8.GetString($Current, $cm.KeyStart, $q + 1 - $cm.KeyStart)
                $text = ",$nl$indent$($keyRaw): $($cm.Raw)"
                $edits.Add(@{ start = $last.ValueEnd; end = $last.ValueEnd; bytes = [Text.Encoding]::UTF8.GetBytes($text); order = $applied.Count })
                $applied.Add($ch)
            }
            'removed' {
                $pm = $p.settings[$k].member
                if (-not $removeByObj.ContainsKey($pm.ObjectPath)) { $removeByObj[$pm.ObjectPath] = New-Object System.Collections.Generic.HashSet[int] }
                [void]$removeByObj[$pm.ObjectPath].Add($pm.Index)
                $applied.Add($ch)
            }
            default { $skipped.Add([pscustomobject]@{ change = $ch; reason = "kind '$($ch.kind)' is informational and is not carried" }) }
        }
    }
    foreach ($objPath in $removeByObj.Keys) {
        $members = $p.parse.Objects[$objPath].Members; $n = $members.Count; $set = $removeByObj[$objPath]
        $i = 0
        while ($i -lt $n) {
            if (-not $set.Contains($i)) { $i++; continue }
            $a = $i; while ($i + 1 -lt $n -and $set.Contains($i + 1)) { $i++ }; $b = $i; $i++
            if ($a -gt 0) { $s = $members[$a - 1].ValueEnd; $e = $members[$b].ValueEnd }
            elseif ($b -lt $n - 1) { $s = $members[$a].KeyStart; $e = $members[$b + 1].KeyStart }
            else { $s = $members[0].KeyStart; $e = $members[$n - 1].ValueEnd }
            $edits.Add(@{ start = $s; end = $e; bytes = [byte[]]@() })
        }
    }
    # apply from the end; inserts at the same offset keep their requested order
    $sorted = @($edits | Sort-Object @{ Expression = { $_.start }; Descending = $true }, @{ Expression = { if ($_.ContainsKey('order')) { $_.order } else { 0 } }; Descending = $true })
    for ($j = 1; $j -lt $sorted.Count; $j++) {
        if ($sorted[$j].end -gt $sorted[$j - 1].start -and $sorted[$j].start -ne $sorted[$j].end) { throw 'Internal error: overlapping SDS edits.' }
    }
    $ms = New-Object System.IO.MemoryStream
    $cursor = $Previous.Length
    $chunks = New-Object System.Collections.Generic.List[byte[]]
    foreach ($ed in $sorted) {
        $tailLen = $cursor - $ed.end
        $tail = New-Object byte[] $tailLen; [Array]::Copy($Previous, $ed.end, $tail, 0, $tailLen)
        $chunks.Insert(0, $tail); $chunks.Insert(0, [byte[]]$ed.bytes)
        $cursor = $ed.start
    }
    $head = New-Object byte[] $cursor; [Array]::Copy($Previous, 0, $head, 0, $cursor)
    $chunks.Insert(0, $head)
    foreach ($ch in $chunks) { $ms.Write($ch, 0, $ch.Length) }
    return @{ bytes = $ms.ToArray(); applied = $applied.ToArray(); skipped = $skipped.ToArray() }
}
