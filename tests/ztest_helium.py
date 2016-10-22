#!/usr/bin/env python
# encoding: utf-8

import os
import re
import sys
import time
import json
import logging
import unittest
from subprocess import Popen, PIPE
from tempfile import NamedTemporaryFile
from string import Template

lua = os.environ.get('ZTEST_LUA') or 'lua'
test_directory = 'tests'
working_directory = os.path.expandvars('$PWD')
sys.path.append(os.path.join(working_directory, 'util'))

from ztest import Lexer, Cases, ContextTestCase

template = '''package.path = "src/?.lua;" .. package.path

local io = io
local cjson = require "cjson.safe"
local parser = require "parser"
local interpreter = require "interpreter"

local function dump(v)
    if type(v) == "table" then
        return cjson.encode(v) or ""
    end

    return tostring(v)
end

local function ast(code)
    io.write(dump(parser.parse(code)))
end

local function interpret(code)
    local i = interpreter.new()
    i:interpret(parser.parse(code))
end

local code = [=[
{0}
]=]

if {ast} then
    ast(code)
else
    interpret(code)
end
'''


def shell(command):
    if isinstance(command, list):
        command = ' '.join(command)
    process = Popen(
        args=command,
        stdout=PIPE,
        shell=True
    )

    return process


def gather_files(test_dir):
    if os.path.isfile(test_dir):
        return [test_dir] if test_dir.endswith('zt') else []

    test_files = []
    for d, _, files in os.walk(test_dir):
        test_files.extend(os.path.join(d, f) for f in
                          filter(lambda f: f.endswith('zt'), files))

    return test_files


class LoggingFormatter(logging.Formatter):
    def __init__(self, fmt, datefmt=None):
        logging.Formatter.__init__(self, fmt, datefmt)
        self.converter = time.gmtime

    def formatException(self, exc_info):
        text = logging.Formatter.formatException(self, exc_info)
        text = '\n'.join(('! %s' % line) for line in text.splitlines())
        return text


def get_console_logger(name):
    logging_fmt = '%(levelname)-8s [%(asctime)s] %(name)s: %(message)s'

    ch = logging.StreamHandler()
    ch.setLevel(logging.DEBUG)
    ch.setFormatter(LoggingFormatter(logging_fmt))

    logger = logging.getLogger(name)
    logger.setLevel(logging.DEBUG)
    logger.addHandler(ch)

    return logger


logger = get_console_logger('ztest')


def LOG_INFO(s):
    logger.log(logging.INFO, '\033[92m%s\033[0m' % s)


def LOG_ERR(s):
    logger.log(logging.ERROR, '\033[91m%s\033[0m' % s)


class Ctx(object):
    def __init__(self, case, env):
        self.case = case
        self.env = env


class TestHelium(ContextTestCase):
    klass_name = 'TestHelium'

    union_items = set(['run', 'ast'])
    assert_items = set(['out'])
    exec_items = set(['assert', 'exec'])
    common_items = set(['setup', 'teardown'])

    teardown_ = None

    def setUp(self):
        self.locals = {'self': self}
        self.globals = None

        if self.ctx is None or not self.ctx.case:
            raise Exception('no test case found')

        self.name = self.ctx.case.name
        self.items = self.ctx.case.items
        if isinstance(self.ctx.env, dict):
            self.globals = self.ctx.env

        self.setup_common()

    def tearDown(self):
        if self.teardown_:
            self.teardown_()

    def setup(self, code):
        self._exec(code)

    def teardown(self, code):
        self.teardown_ = lambda: self._exec(code)

    def setup_common(self):
        for idx, item in enumerate(self.items):
            if item.name in self.common_items:
                self.eval_item(item)
                getattr(self, item.name)(item.value)
            else:
                break
        self.items = self.items[idx:]

    def skip(self):
        return self.__class__.__name__ == self.klass_name

    def blocks_iter(self):
        block = {}
        for item in self.items:
            self.eval_item(item)
            if item.name in self.union_items:
                if item.name in block:
                    yield block
                    block = {}
                block[item.name] = item
            else:
                if block:
                    yield block
                    block = {}
                yield item

    def eval_item(self, item):
        for op in item.option:
            if op == 'eval':
                item.value = self._eval(item.value)
            elif op == 'template':
                item.value = Template(item.value).safe_substitute(self.globals)
            elif op == 'json':
                item.value = json.loads(item.value)
            else:
                break

    def _exec(self, code):
        exec(code, self.globals, self.locals)

    def _eval(self, code):
        return eval(code, self.globals, self.locals)

    def more_assert(self, pattern, text, option):
        if 'like' in option:
            assert re.search(pattern, text), text
        elif 'unlike' in option:
            assert not re.search(pattern, text), text
        else:
            self.assertEqual(pattern, text)

    def assert_out(self, out, item):
        self.more_assert(item.value, out, item.option)

    def do_assert(self, item):
        if item.name in self.exec_items or 'exec' in item.option:
            return self._exec(item.value)

        out = self.locals['out']
        assert out is not None, 'assert what?'
        getattr(self, 'assert_' + item.name)(out, item)

    def run_block(self, block):
        f = NamedTemporaryFile(delete=True)
        if 'ast' in block:
            f.write(template.format(block['ast'].value, ast="true"))
        else:
            f.write(template.format(block['run'].value, ast="false"))
        f.flush()
        try:
            p = shell([lua, f.name])
            self.locals['out'] = p.communicate()[0]
        finally:
            f.close()

    def test_run(self):
        if self.skip() or self.items is None:
            return
        for block in self.blocks_iter():
            if isinstance(block, dict):
                self.run_block(block)
                continue
            try:
                self.do_assert(block)
            except:
                LOG_ERR('%s at line: %d' % (block.name, block.lineno))
                raise


def add_test_case(zt, suite, cases, env, klass=None,
                  run_only=None, run_except=None):
    for case in cases:
        if case.name is None:
            case.name = ''
        if run_only and not re.search(run_only, case.name):
            LOG_INFO('Skip test case: %s' % case.name)
            continue
        if run_except and re.search(run_except, case.name):
            LOG_INFO('Skip test case: %s' % case.name)
            continue
        case.name = re.sub(r'[^.\w]+', '_', case.name)
        suite.addTest(
            ContextTestCase.addContext(
                type('%s<%s +%s>' % (case.name, zt, case.lineno),
                     (klass,), {}), ctx=Ctx(case, env)))


def run_test_suite(suite):
    r = unittest.TextTestRunner(verbosity=2).run(suite)
    if r and (r.errors or r.failures):
        sys.exit(1)


def run_tests(klass, klass_name):
    td = os.environ.get('ZTEST_DIR')
    if td is None:
        td = test_directory

    zts = gather_files(td)
    if not zts:
        return

    for zt in zts:
        run_only_file = os.environ.get('ZTEST_RUN_ONLY_FILE')
        if run_only_file and not re.search(run_only_file, zt):
            LOG_INFO('Skip test file: %s' % zt)
            continue
        run_except_file = os.environ.get('ZTEST_RUN_EXCEPT_FILE')
        if run_except_file and re.search(run_except_file, zt):
            LOG_INFO('Skip test file: %s' % zt)
            continue

        env, suite = {klass_name: klass}, unittest.TestSuite()
        g, cases = Cases()(Lexer()(open(zt).read()))

        if g.get('setup'):
            exec(g['setup'], env, None)

        run_only = os.environ.get('ZTEST_RUN_ONLY')
        run_except = os.environ.get('ZTEST_RUN_EXCEPT')
        add_test_case(zt, suite, cases, env, klass=klass,
                      run_only=run_only, run_except=run_except)

        try:
            run_test_suite(suite)
        finally:
            if g.get('teardown'):
                exec(g['teardown'], env, None)


run_tests(TestHelium, 'TestHelium')
