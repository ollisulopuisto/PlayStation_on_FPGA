#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Experimental SFL+ -> SystemVerilog compiler for isolated block validation.

Supports guarded combinational logic, registers, one-port memories, local
control terminals/arguments, lexical locals, switch and single-task stages.
Not a qualified full-core compiler. See docs/POCKET_SFLC.md for semantic limits.
Unsupported constructs fail rather than silently disappear.

Usage: sflc.py [-D NAME]... [--assertions] file.sflp > out.sv
"""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import sflp_parse  # noqa: E402

BIN = {'|': '|', '&': '&', '@': '^', '+': '+', '-': '-', '*': '*',
       '==': '==', '!=': '!=', '<<': '<<', '>>': '>>'}
UN = {'^': '~', '~': '~', '!': '!', '-': '-', '/|': '|', '/&': '&',
      '/@': '^', '/^': '^'}
REGS = ('reg', 'reg_wr', 'reg_ws')


def constant(n):
    """Evaluate declaration bounds; runtime expressions are not bounds."""
    k = n[0]
    if k == 'num':
        return int(n[1])
    if k == 'const':
        return int(n[1].replace('_', ''), 0)
    if k == 'paren':
        return constant(n[1])
    if k == 'un' and n[1] == '-':
        return -constant(n[2])
    if k == 'chain':
        v = constant(n[1][0])
        for op, rhs in zip(n[2], n[1][1:]):
            r = constant(rhs)
            if op == '+': v += r
            elif op == '-': v -= r
            elif op == '*': v *= r
            else: raise NotImplementedError('constant operator ' + op)
        return v
    raise NotImplementedError('nonconstant declaration/bound: ' + repr(n))


def const_text(kind, val):
    if kind == 'num':
        return val
    base = {'x': 'h', 'b': 'b', 'o': 'o'}[val[1].lower()]
    digits = val[2:].replace('_', '')
    width = len(digits) * {'b': 1, 'o': 3, 'h': 4}[base]
    return "%d'%s%s" % (width, base, digits)


class Scope:
    """Hoist declarations after alpha-renaming each lexical block.

    Declarations are visible throughout their containing block (SFL+ accepts
    declaration after use). Sibling block locals never share a register/wire.
    """
    def __init__(self):
        self.declarations = []
        self.serial = 0

    def expr(self, n, env):
        if not isinstance(n, tuple):
            return n
        if n[0] == 'name':
            if n[1] not in env:
                raise NameError('undeclared ' + n[1])
            return ('name', env[n[1]])
        if n[0] == 'dot':
            return ('dot', self.expr(n[1], env), n[2])
        return tuple(self.expr(x, env) if isinstance(x, tuple) else
                     [self.expr(y, env) for y in x] if isinstance(x, list) else x
                     for x in n)

    def block(self, items, outer, root=False):
        env = dict(outer)
        local = set()
        for item in items:
            d = item[1] if item[0] == 'item' else item
            names = ([e['name'] for e in d[2]] if d[0] == 'decl' else
                     [d[1]] if d[0] == 'stage_name' else [])
            for name in names:
                if name in local or name in ('p_reset', 'm_clock') or name.startswith('__sfl_'):
                    raise ValueError('duplicate/reserved declaration ' + name)
                local.add(name)
                self.serial += 1
                env[name] = name if root else '__sfl_local_%d_%s' % (self.serial, name)
        out = []
        for item in items:
            d = item[1] if item[0] == 'item' else item
            if d[0] == 'decl':
                entries = []
                for e in d[2]:
                    ent = dict(e, name=env[e['name']])
                    for key in ('width', 'depth', 'init'):
                        if key in ent: ent[key] = self.expr(ent[key], env)
                    if 'args' in ent: ent['args'] = [env[a] for a in ent['args']]
                    entries.append(ent)
                self.declarations.append(('decl', d[1], entries))
            elif d[0] == 'stage_name':
                if not root:
                    raise NotImplementedError('nested stage declaration')
                self.declarations.append(('stage_name', env[d[1]],
                                          [(t, [env[a] for a in args]) for t, args in d[2]]))
            elif d[0] == 'instr_arg':
                self.declarations.append(('instr_arg', env[d[1]], [env[a] for a in d[2]]))
            else:
                out.append(self.action(item, env))
        return out

    def action(self, a, env):
        k = a[0]
        if k in ('par', 'join'):
            if a[1] is not None or k == 'join':
                raise NotImplementedError(k + ' generator')
            return ('par', None, self.block(a[2], env), a[-1])
        if k in ('any', 'alt'):
            if a[1] is not None: raise NotImplementedError(k + ' generator')
            return (k, None, [(self.expr(g, env), self.action(b, env)) for g, b in a[2]],
                    None if a[3] is None else self.action(a[3], env), a[-1])
        if k == 'if':
            return (k, self.expr(a[1], env), self.action(a[2], env),
                    None if a[3] is None else self.action(a[3], env), a[-1])
        if k == 'switch':
            return (k, self.expr(a[1], env),
                    [(None if key is None else self.expr(key, env), self.block(body, env))
                     for key, body in a[2]], a[-1])
        if k in ('always', 'common'):
            return (k, self.action(a[1], env))
        if k == 'instruct':
            if a[1] not in env: raise NameError('undeclared instruction ' + a[1])
            return (k, env[a[1]], self.action(a[2], env), a[-1])
        if k == 'stage':
            if a[1] not in env: raise NameError('undeclared stage ' + a[1])
            return (k, env[a[1]], self.block(a[2], env), a[-1])
        if k == 'state':
            return (k, a[1], self.action(a[2], env), a[-1])
        if k in ('state_name', 'first_state', 'goto', 'finish', 'nop'):
            return a
        if k in ('generate', 'relay'):
            if a[1] not in env: raise NameError('undeclared stage ' + a[1])
            return (k, env[a[1]], a[2], [self.expr(x, env) for x in a[3]], a[-1])
        if k == 'item':
            # A single declaration/instruct used as a branch's entire action.
            return ('par', None, self.block([a[1]], env), 0)
        if k in ('decl', 'inst', 'declare', 'stage_name', 'instr_arg'):
            raise NotImplementedError('circuit item ' + k)
        return self.expr(a, env)


class Gen:
    def __init__(self, name, assertions=False):
        self.name = name
        self.assertions = assertions
        self.ports = []
        self.decls = {}       # name -> bit count (always numeric)
        self.kinds = {}
        self.resets = {}      # registers with asynchronous reset values
        self.memories = {}    # name -> (depth, initial values or None)
        self.instructions = {}  # terminal -> formal signal names
        self.stages = {}
        self.drivers = {}     # target -> [(guards, expression)]
        self.writes = {}      # memory -> [(guards, address, expression)]
        self.temps = []

    def temp(self, expr, width):
        name = '__sfl_expr_%d' % len(self.temps)
        self.temps.append((name, width, expr))
        return name

    def width_name(self, name):
        if name not in self.decls: raise NameError('undeclared ' + name)
        return self.decls[name]

    def width(self, n):
        k = n[0]
        if k == 'name': return self.width_name(n[1])
        if k == 'num': return max(1, int(n[1]).bit_length())
        if k == 'const': return len(n[1][2:].replace('_', '')) * {'x': 4, 'b': 1, 'o': 3}[n[1][1].lower()]
        if k == 'paren': return self.width(n[1])
        if k == 'sext': return n[1]
        if k == 'slice':
            return 1 if n[3] is None else abs(constant(n[2]) - constant(n[3])) + 1
        if k == 'index': return self.width(n[1])
        if k == 'dot':
            self.stage_ref(n)
            return 1
        if k == 'un': return 1 if n[1] in ('/|', '/&', '/@', '/^', '!') else self.width(n[2])
        if k == 'chain':
            w = self.width(n[1][0])
            for op, t in zip(n[2], n[1][1:]):
                if op == '||': w += self.width(t)
                elif op in ('==', '!='): w = 1
                elif op not in ('<<', '>>'): w = max(w, self.width(t))
            return w
        raise NotImplementedError('expression width ' + k)

    def stage_ref(self, n):
        if n[1][0] != 'name' or n[1][1] not in self.stages:
            raise NotImplementedError('submodule expression')
        st = self.stages[n[1][1]]
        if n[2] != st['task']: raise NameError('unknown stage task ' + n[2])
        return st

    def expr(self, n, context=None):
        k = n[0]
        if k == 'name':
            self.width_name(n[1])
            if self.kinds[n[1]] == 'mem': raise ValueError('memory requires index')
            return n[1]
        if k == 'num':
            # Decimal SFL literals inherit the enclosing data width. Size them
            # explicitly so Verilog cannot sign-extend or widen a concatenation.
            return "%d'd%s" % (context or self.width(n), n[1])
        if k == 'const': return const_text(k, n[1])
        if k == 'paren': return '(' + self.expr(n[1], context) + ')'
        if k == 'dot': return self.stage_ref(n)['active']
        if k == 'index':
            if n[1][0] != 'name' or n[1][1] not in self.memories:
                raise NotImplementedError('index of non-memory')
            return '%s[%s]' % (n[1][1], self.expr(n[2]))
        if k == 'chain':
            # Build a binary tree with SFL's left-to-right rule, then let the
            # surrounding operation determine decimal-literal sizing.
            tree = n[1][0]
            for op, t in zip(n[2], n[1][1:]): tree = ('binary', op, tree, t)
            return self.binary(tree, context)
        if k == 'un':
            if n[1] not in UN: raise NotImplementedError('unary ' + n[1])
            return '%s(%s)' % (UN[n[1]], self.expr(n[2], context))
        if k == 'slice':
            hi = constant(n[2]); lo = hi if n[3] is None else constant(n[3])
            w = self.width(n[1])
            if min(hi, lo) < 0 or max(hi, lo) >= w:
                raise ValueError('slice outside expression width: ' + repr(n))
            base = self.expr(n[1])
            if n[1][0] != 'name': base = self.temp(base, w)
            if hi < lo: return '{' + ','.join('%s[%d]' % (base, b) for b in range(hi, lo + 1)) + '}'
            if hi == lo: return base if w == 1 else '%s[%d]' % (base, hi)
            return '%s[%d:%d]' % (base, hi, lo)
        if k == 'sext':
            total, src = n[1], n[2]
            w = self.width(src)
            if total < w: raise ValueError('sign extension cannot narrow')
            base = self.expr(src)
            if total == w: return base
            # Arbitrary expressions use a sized temporary so the sign bit is
            # taken before extension, independent of destination context.
            tmp = base if src[0] == 'name' else self.temp(base, w)
            sign = tmp if w == 1 else '%s[%d]' % (tmp, w - 1)
            return '{{%d{%s}},%s}' % (total - w, sign, tmp)
        raise NotImplementedError('expression ' + k)

    def binary_width(self, n):
        if n[0] != 'binary': return self.width(n)
        _, op, a, b = n
        wa, wb = self.binary_width(a), self.binary_width(b)
        if op == '||': return wa + wb
        if op in ('==', '!='): return 1
        if op in ('<<', '>>'): return wa
        return max(wa, wb)

    def binary(self, n, context):
        if n[0] != 'binary': return self.expr(n, context)
        _, op, a, b = n
        wa, wb = self.binary_width(a), self.binary_width(b)
        if op == '||': return '{%s,%s}' % (self.binary(a, None), self.binary(b, None))
        if op not in BIN: raise NotImplementedError('binary operator ' + op)
        if op in ('==', '!='): ctx = max(wa, wb)
        elif op in ('<<', '>>'): ctx = max(wa, context or 0)
        else: ctx = max(wa, wb, context or 0)
        return '((%s)%s(%s))' % (self.binary(a, ctx), BIN[op],
                                 self.binary(b, None if op in ('<<', '>>') else ctx))

    def add_decl(self, name, kind, width):
        if name in self.decls: raise ValueError('duplicate declaration ' + name)
        if width < 1: raise ValueError('nonpositive width ' + name)
        self.decls[name], self.kinds[name] = width, kind

    def declare(self, item):
        kw = item[1]
        for ent in item[2]:
            n = ent['name']
            w = constant(ent['width']) if 'width' in ent else 1
            if kw not in ('input', 'output', 'sel', 'instrin', 'instrout', 'instrself', 'mem') + REGS:
                raise NotImplementedError('declaration ' + kw)
            if kw.startswith('instr') and w != 1: raise ValueError('control width must be one')
            self.add_decl(n, kw, w)
            if kw in ('input', 'output', 'instrin', 'instrout'):
                self.ports.append(('input' if kw in ('input', 'instrin') else 'output', n, w))
            if kw.startswith('instr'): self.instructions[n] = ent.get('args', [])
            if kw == 'reg_wr': self.resets[n] = "'0"
            if kw == 'reg_ws': self.resets[n] = "%d'h%x" % (w, (1 << w) - 1)
            if 'depth' in ent:
                depth = constant(ent['depth'])
                if depth < 1: raise ValueError('nonpositive memory depth')
                vals = ent.get('init')
                if vals is not None:
                    if vals[0] != 'list': raise ValueError('memory initialization requires list')
                    vals = [constant(value) & ((1 << w) - 1) for value in vals[1]]
                    if len(vals) > depth: raise ValueError('too many memory initializers')
                self.memories[n] = (depth, vals)
            elif 'init' in ent:
                if kw != 'reg': raise NotImplementedError('initializer on ' + kw)
                self.resets[n] = "%d'd%d" % (w, constant(ent['init']) & ((1 << w) - 1))

    def drive(self, target, guards, value, sequential=False):
        if target not in self.kinds: raise NameError('undeclared target ' + target)
        expected = REGS if sequential else ('sel', 'output', 'instrout', 'instrself')
        if self.kinds[target] not in expected:
            raise ValueError('wrong assignment kind for ' + target)
        self.drivers.setdefault(target, []).append((list(guards), value))

    def assign(self, lhs, rhs, guards, sequential):
        if lhs[0] == 'index' and sequential:
            if lhs[1][0] != 'name' or lhs[1][1] not in self.memories:
                raise ValueError('write target is not a memory')
            name = lhs[1][1]
            self.writes.setdefault(name, []).append((list(guards), self.expr(lhs[2]),
                                                     self.expr(rhs, self.decls[name])))
        elif lhs[0] == 'name':
            self.drive(lhs[1], guards, self.expr(rhs, self.width_name(lhs[1])), sequential)
        else:
            raise NotImplementedError('indexed/sliced assignment target')

    def action(self, a, guards, stage=None):
        k = a[0]
        if k == 'assign':
            self.assign(a[2], a[3], guards, a[1] == ':=')
        elif k in ('incdec', 'opassign'):
            op = ('+' if a[1] == '++' else '-') if k == 'incdec' else a[1][0]
            rhs = ('num', '1') if k == 'incdec' else a[3]
            self.assign(a[2], ('chain', [a[2], rhs], [op]), guards, True)
        elif k in ('always', 'common'):
            self.action(a[1], guards, stage)
        elif k == 'instruct':
            if a[1] not in self.instructions: raise ValueError('instruct requires control terminal')
            self.action(a[2], guards + [a[1]], stage)
        elif k == 'invoke':
            if a[1][0] != 'name': raise NotImplementedError('submodule invocation')
            name = a[1][1]
            if name not in self.instructions or self.kinds[name] == 'instrin':
                raise ValueError('cannot invoke ' + name)
            args = self.instructions[name]
            if len(args) != len(a[2]): raise ValueError('argument count for ' + name)
            self.drive(name, guards, "1'b1")
            for formal, actual in zip(args, a[2]):
                self.drive(formal, guards, self.expr(actual, self.decls[formal]))
        elif k == 'if':
            c = self.expr(a[1])
            self.action(a[2], guards + [c], stage)
            if a[3] is not None: self.action(a[3], guards + ['!(%s)' % c], stage)
        elif k in ('any', 'alt'):
            seen = []
            for cond, body in a[2]:
                c = self.expr(cond)
                prior = ['!(%s)' % x for x in seen] if k == 'alt' else []
                self.action(body, guards + prior + [c], stage)
                seen.append(c)
            if a[3] is not None:
                self.action(a[3], guards + ['!(%s)' % x for x in seen], stage)
        elif k == 'switch':
            keys = [constant(key) for key, _ in a[2] if key is not None]
            if len(set(keys)) != len(keys) or sum(key is None for key, _ in a[2]) > 1:
                raise ValueError('duplicate switch case/default')
            width = self.width(a[1])
            if any(key < 0 or key >= 1 << width for key in keys):
                raise ValueError('switch case does not fit selector')
            sel = self.expr(a[1]); matches = ['(%s == %d\'d%d)' % (sel, width, key) for key in keys]
            for key, body in a[2]:
                branch = ['!(%s)' % m for m in matches] if key is None else [
                    '(%s == %d\'d%d)' % (sel, width, constant(key))]
                for x in body: self.action(x, guards + branch, stage)
        elif k == 'par':
            for x in a[2]: self.action(x, guards, stage)
        elif k == 'generate':
            st = self.stages[a[1]]
            if a[2] != st['task'] or len(a[3]) != len(st['args']):
                raise ValueError('stage task/argument mismatch')
            st['start'].append(list(guards))
            for formal, actual in zip(st['args'], a[3]):
                self.drive(formal, guards, self.expr(actual, self.decls[formal]), True)
        elif k in ('goto', 'finish'):
            if stage is None: raise ValueError(k + ' outside stage')
            if k == 'finish': stage['stop'].append(list(guards))
            else:
                if a[1] not in stage['states']: raise NameError('unknown state ' + a[1])
                value = "%d'd%d" % (self.decls[stage['state']], stage['states'].index(a[1]))
                self.drive(stage['state'], guards, value, True)
        elif k == 'stage':
            st = self.stages[a[1]]
            for item in a[2]:
                if item[0] in ('state_name', 'first_state'): continue
                if item[0] == 'state':
                    g = '%s == %d' % (st['state'], st['states'].index(item[1]))
                    self.action(item[2], guards + [st['active'], g], st)
                else: self.action(item, guards + [st['active']], st)
        elif k == 'nop': pass
        else: raise NotImplementedError('statement ' + k)

    def run(self, circuit):
        scope = Scope()
        body = scope.block(circuit[2], {}, root=True)
        for item in scope.declarations:
            if item[0] == 'decl': self.declare(item)
        for item in scope.declarations:
            if item[0] == 'instr_arg':
                if item[1] not in self.instructions: raise ValueError('instr_arg without instruction')
                self.instructions[item[1]] = item[2]
            elif item[0] == 'stage_name':
                if len(item[2]) != 1: raise NotImplementedError('multiple tasks in one stage')
                name = item[1]; task, args = item[2][0]
                for arg in args:
                    if self.kinds.get(arg) not in REGS: raise ValueError('stage argument must be a register')
                active = '__sfl_active_' + name
                self.add_decl(active, 'reg_wr', 1); self.resets[active] = "1'b0"
                self.stages[name] = dict(task=task, args=args, active=active,
                                         states=[], start=[], stop=[], body=False)
        for name, args in self.instructions.items():
            allowed = ('input',) if self.kinds[name] == 'instrin' else ('sel', 'output')
            for arg in args:
                if self.kinds.get(arg) not in allowed: raise ValueError('invalid argument signal for ' + name)
        for item in body:
            if item[0] != 'stage': continue
            st = self.stages[item[1]]
            if st['body']: raise ValueError('duplicate stage body')
            st['body'] = True
            states = [x[1] for x in item[2] if x[0] == 'state']
            if len(set(states)) != len(states): raise ValueError('duplicate state')
            st['states'] = states
            declared = [s for x in item[2] if x[0] == 'state_name' for s in x[1]]
            if declared and set(declared) != set(states): raise ValueError('state_name/body mismatch')
            first = [s for x in item[2] if x[0] == 'first_state' for s in x[1]]
            if states:
                if len(first) != 1 or first[0] not in states: raise ValueError('stage needs one valid first_state')
                state = '__sfl_state_' + item[1]
                self.add_decl(state, 'reg', max(1, (len(states) - 1).bit_length()))
                self.resets[state] = str(states.index(first[0])); st['state'] = state
            elif first: raise ValueError('first_state without state body')
        for st in self.stages.values():
            if not st['body']: raise ValueError('stage declaration without body')
        for item in body: self.action(item, [])
        return self.emit()

    @staticmethod
    def guard(guards):
        return ' && '.join('(%s)' % x for x in guards) or "1'b1"

    def mux(self, terms):
        return ' | '.join('((%s) ? (%s) : \'0)' % (self.guard(gs), val)
                          for gs, val in terms) or "'0"

    def conflict_checks(self, terms, label):
        if not self.assertions: return []
        lines = []
        for i, (ga, _) in enumerate(terms):
            for gb, _ in terms[i+1:]:
                lines.append('    if ((%s) && (%s)) $fatal(1, "conflicting drivers: %s");' %
                             (self.guard(ga), self.guard(gb), label))
        return lines

    def emit(self):
        def rng(w): return '[%d:0] ' % (w - 1) if w > 1 else ''
        L = ['// Experimental sflc output; see docs/POCKET_SFLC.md.',
             'module %s (%s);' % (self.name, ', '.join(['p_reset', 'm_clock'] + [p[1] for p in self.ports])),
             '  input p_reset, m_clock;']
        port_names = {p[1] for p in self.ports}
        for d, n, w in self.ports: L.append('  %s %s%s;' % (d, rng(w), n))
        for n, w in self.decls.items():
            if n in port_names: continue
            kind = self.kinds[n]
            dims = ' [0:%d]' % (self.memories[n][0] - 1) if kind == 'mem' else ''
            L.append('  %s %s%s%s;' % ('reg' if kind in REGS + ('mem',) else 'wire', rng(w), n, dims))
        for n, w, expr in self.temps:
            L.append('  wire %s%s = %s;' % (rng(w), n, expr))
        for n, kind in self.kinds.items():
            if kind in ('sel', 'output', 'instrself', 'instrout'):
                L.append('  assign %s = %s;' % (n, self.mux(self.drivers.get(n, []))))
        for n, kind in self.kinds.items():
            if kind not in REGS: continue
            if any(st['active'] == n for st in self.stages.values()): continue
            terms = self.drivers.get(n, [])
            reset = self.resets.get(n)
            if not terms and reset is None: continue
            events = 'posedge m_clock' + (' or posedge p_reset' if reset is not None else '')
            L.append('  always @(%s) begin' % events)
            if reset is not None: L.append('    if (p_reset) %s <= %s;' % (n, reset))
            if terms:
                enable = ' || '.join('(%s)' % self.guard(g) for g, _ in terms)
                L.append('    %sif (%s) %s <= %s;' % ('else ' if reset is not None else '', enable, n, self.mux(terms)))
            L.append('  end')
        for name, (depth, vals) in self.memories.items():
            if vals is not None:
                L.append('  initial begin')
                L.append("    for (integer i = 0; i < %d; i = i + 1) %s[i] = '0;" % (depth, name))
                for i, val in enumerate(vals):
                    L.append("    %s[%d] = %d'd%d;" % (name, i, self.decls[name], val))
                L.append('  end')
            writes = self.writes.get(name, [])
            # A single physical write port: select the address and data under
            # the same guards. Assert multiple writers instead of inventing
            # source-order priority or inferring accidental multiport RAM.
            if writes:
                addr = [(g, a) for g, a, _ in writes]; data = [(g, v) for g, _, v in writes]
                enable = ' || '.join('(%s)' % self.guard(g) for g, _, _ in writes)
                L.append('  always @(posedge m_clock) if (%s) %s[%s] <= %s;' %
                         (enable, name, self.mux(addr), self.mux(data)))
        for st in self.stages.values():
            start = ' || '.join('(%s)' % self.guard(g) for g in st['start']) or "1'b0"
            stop = ' || '.join('(%s)' % self.guard(g) for g in st['stop']) or "1'b0"
            L += ['  always @(posedge m_clock or posedge p_reset) begin',
                  "    if (p_reset) %s <= 1'b0;" % st['active'],
                  "    else %s <= (%s) || (%s && !(%s));" % (st['active'], start, st['active'], stop), '  end']
        if self.assertions:
            checks = []
            for n, terms in self.drivers.items():
                if self.kinds[n] not in ('instrout', 'instrself'):
                    checks += self.conflict_checks(terms, n)
            for n, writes in self.writes.items(): checks += self.conflict_checks([(g, v) for g, _, v in writes], n)
            # Busy regeneration is deliberately outside the qualified subset.
            for name, st in self.stages.items():
                for g in st['start']:
                    checks.append('    if ((%s) && %s) $fatal(1, "unverified stage regeneration: %s");' %
                                  (self.guard(g), st['active'], name))
            if checks: L += ['  // synthesis translate_off', '  always @(posedge m_clock) if (!p_reset) begin'] + checks + ['  end', '  // synthesis translate_on']
        return '\n'.join(L + ['endmodule', ''])


def translate(path, defines=(), assertions=False):
    ast, includes = sflp_parse.parse_file(path, defines)
    if includes: raise NotImplementedError('%i includes (interface linking is not implemented)')
    circuits = [c for c in ast if c[0] in ('circuit', 'module')]
    if len(circuits) != 1: raise NotImplementedError('expected exactly one circuit')
    return Gen(circuits[0][1], assertions).run(circuits[0])


def main(argv):
    defines, files, assertions = [], [], False
    it = iter(argv)
    for a in it:
        if a == '-D': defines.append(next(it))
        elif a == '--assertions': assertions = True
        else: files.append(a)
    if len(files) != 1:
        print(__doc__, file=sys.stderr); return 2
    try:
        sys.stdout.write(translate(files[0], defines, assertions))
    except (NotImplementedError, ValueError, NameError, SyntaxError) as exc:
        print('%s: %s: %s' % (files[0], type(exc).__name__, exc), file=sys.stderr)
        return 1
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
