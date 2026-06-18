// Copyright (c) 2026, WSO2 LLC. (https://www.wso2.com).
//
// WSO2 LLC. licenses this file to you under the Apache License,
// Version 2.0 (the "License"); you may not use this file except
// in compliance with the License.
// You may obtain a copy of the License at
//
// http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing,
// software distributed under the License is distributed on an
// "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
// KIND, either express or implied.  See the License for the
// specific language governing permissions and limitations
// under the License.

package agent

import (
	"testing"

	"github.com/wso2/agent-manager/cli/pkg/cmdutil"
	"github.com/wso2/agent-manager/cli/pkg/iostreams"
)

func TestNewAgentCmd_RegistersLLM(t *testing.T) {
	ios, _, _, _ := iostreams.Test()
	cmd := NewAgentCmd(&cmdutil.Factory{IOStreams: ios})

	for _, c := range cmd.Commands() {
		if c.Name() == "llm" {
			return
		}
	}
	t.Fatal("llm command group not registered under agent")
}
