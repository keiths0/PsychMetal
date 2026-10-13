"""Portable report persistence and explicit, offline export for the phone UI."""
import json
import os
from pathlib import Path
import tempfile
from psychmetal.environment import _json_value


class Reports:
    def __init__(self, directory=None):
        self.directory = None if directory is None else Path(directory)
        self.data = {'schemaVersion':1, 'environment':None, 'timingHTML':None, 'timingEnvironment':None, 'output':None}
        if self.directory is not None:
            self.directory.mkdir(parents=True, exist_ok=True)
            self.path = self.directory/'last-report.json'
            try:
                data=json.loads(self.path.read_text(encoding='utf-8'))
                if not isinstance(data,dict) or data.get('schemaVersion')!=1:
                    raise ValueError('Unknown report format.')
                for key in ('timingHTML','output'):
                    if data.get(key) is not None and not isinstance(data[key],str):
                        raise ValueError('Invalid report text.')
                if data.get('environment') is not None and not isinstance(data['environment'],dict):
                    raise ValueError('Invalid environment report.')
                self.data.update({key:data.get(key) for key in self.data if key!='schemaVersion'})
            except (OSError,ValueError,TypeError):
                pass  # An incomplete/older report must never stop the menu opening.

    def update(self, output=None, timing=None, environment=None):
        if output is not None:self.data['output']=output
        if timing is not None:self.data['timingHTML']=timing
        if environment is not None:self.data['environment']=_json_value(environment)
        if timing is not None:self.data['timingEnvironment']=_json_value(environment)
        if self.directory is None:return
        text=json.dumps(self.data,allow_nan=False,ensure_ascii=False,indent=2)+'\n'
        temporary=None
        try:
            with tempfile.NamedTemporaryFile(mode='w',encoding='utf-8',dir=self.directory,delete=False) as stream:
                temporary=Path(stream.name);stream.write(text);stream.flush();os.fsync(stream.fileno())
            temporary.replace(self.path)
        finally:
            if temporary is not None:temporary.unlink(missing_ok=True)

    def export(self, directory):
        directory=Path(directory);directory.mkdir(parents=True,exist_ok=True)
        files=[]
        for name,key in (('timing-report.html','timingHTML'),('demo-output.txt','output')):
            if self.data[key] is not None:
                path=directory/name;path.write_text(self.data[key],encoding='utf-8');files.append(path)
        if self.data['environment'] is not None:
            path=directory/'environment.json'
            path.write_text(json.dumps(_json_value(self.data['environment']),allow_nan=False,indent=2)+'\n',encoding='utf-8');files.append(path)
        if self.data.get('timingEnvironment') is not None:
            path=directory/'timing-environment.json'
            path.write_text(json.dumps(_json_value(self.data['timingEnvironment']),allow_nan=False,indent=2)+'\n',encoding='utf-8');files.append(path)
        return files
