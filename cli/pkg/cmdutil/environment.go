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

package cmdutil

import (
	amsvc "github.com/wso2/agent-manager/cli/pkg/clients/amsvc/gen"
)

// LowestEnvironment returns the entry environment of the deployment pipeline —
// the SourceEnvironmentRef that does not appear anywhere as a target. Mirrors
// the server-side selection rule; replicated client-side so commands can pick
// the same environment the platform deploys to first. Returns "" when the
// pipeline has no entry environment.
func LowestEnvironment(paths []amsvc.PromotionPath) string {
	targets := make(map[string]struct{})
	for _, p := range paths {
		for _, t := range p.TargetEnvironmentRefs {
			targets[t.Name] = struct{}{}
		}
	}
	for _, p := range paths {
		if _, isTarget := targets[p.SourceEnvironmentRef]; !isTarget {
			return p.SourceEnvironmentRef
		}
	}
	return ""
}
