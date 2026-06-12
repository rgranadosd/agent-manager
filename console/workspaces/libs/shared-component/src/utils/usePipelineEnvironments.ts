/**
 * Copyright (c) 2025, WSO2 LLC. (https://www.wso2.com).
 *
 * WSO2 LLC. licenses this file to you under the Apache License,
 * Version 2.0 (the "License"); you may not use this file except
 * in compliance with the License.
 * You may obtain a copy of the License at
 *
 * http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing,
 * software distributed under the License is distributed on an
 * "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
 * KIND, either express or implied.  See the License for the
 * specific language governing permissions and limitations
 * under the License.
 */

import {
    useGetProject,
    useListDeploymentPipelines,
    useListEnvironments,
} from "@agent-management-platform/api-client";
import type {
    DeploymentPipelineListResponse,
    Environment,
    ProjectResponse,
} from "@agent-management-platform/types";
import { useMemo } from "react";

/**
 * Returns only the environments that belong to the given project's deployment
 * pipeline, ordered by the pipeline's promotion chain.
 *
 * Branched promotion graphs (a → b, a → c, b → d, c → d) are ordered via a
 * topological sort instead of following only the first outgoing edge of each
 * node. Environments not referenced by the pipeline are dropped.
 *
 * Fallback: when the pipeline has no promotion paths (e.g. not yet loaded or a
 * single-environment pipeline that we can't enumerate), all environments are
 * returned so the caller never renders an empty list.
 */
export function orderPipelineEnvironments(
    environments: Environment[] | undefined,
    pipelinesData: DeploymentPipelineListResponse | undefined,
    project: ProjectResponse | undefined,
): Environment[] {
    if (!environments) return [];

    const paths = pipelinesData?.deploymentPipelines
        ?.find((p) => p.name === project?.deploymentPipeline)
        ?.promotionPaths ?? [];

    if (!paths.length) return environments;

    const adjacency = new Map<string, string[]>();
    const allNodes = new Set<string>();
    const inDegree = new Map<string, number>();

    for (const p of paths) {
        const targets = p.targetEnvironmentRefs.map((t) => t.name).filter(Boolean);
        adjacency.set(p.sourceEnvironmentRef, targets);
        allNodes.add(p.sourceEnvironmentRef);
        inDegree.set(p.sourceEnvironmentRef, inDegree.get(p.sourceEnvironmentRef) ?? 0);
        for (const t of targets) {
            allNodes.add(t);
            inDegree.set(t, (inDegree.get(t) ?? 0) + 1);
        }
    }

    const chain: string[] = [];
    const queue = [...allNodes].filter((n) => (inDegree.get(n) ?? 0) === 0);
    while (queue.length > 0) {
        const node = queue.shift()!;
        chain.push(node);
        for (const neighbor of adjacency.get(node) ?? []) {
            const deg = (inDegree.get(neighbor) ?? 1) - 1;
            inDegree.set(neighbor, deg);
            if (deg === 0) queue.push(neighbor);
        }
    }

    // Fallback for cycles/invalid graphs: keep any node that didn't make it into
    // the topo order so we never silently drop pipeline environments.
    allNodes.forEach((n) => { if (!chain.includes(n)) chain.push(n); });

    return chain
        .map((name) => environments.find((e) => e.name === name))
        .filter(Boolean) as Environment[];
}

/**
 * Hook wrapper around {@link orderPipelineEnvironments} that fetches the
 * environments, project and pipelines for the given org/project and returns the
 * pipeline-scoped, promotion-ordered environment list.
 */
export function usePipelineEnvironments(orgId?: string, projectId?: string): Environment[] {
    const { data: environments } = useListEnvironments({ orgName: orgId });
    const { data: project } = useGetProject({ orgName: orgId, projName: projectId });
    const { data: pipelinesData } = useListDeploymentPipelines({ orgName: orgId });

    return useMemo(
        () => orderPipelineEnvironments(environments, pipelinesData, project),
        [environments, pipelinesData, project],
    );
}
