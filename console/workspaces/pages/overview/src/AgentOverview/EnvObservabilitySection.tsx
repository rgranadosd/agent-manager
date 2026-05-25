/**
 * Copyright (c) 2026, WSO2 LLC. (https://www.wso2.com).
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

import React from "react";
import {
    Box,
    Button,
    Card,
    CardContent,
    Divider,
    ListingTable,
    Skeleton,
    Stack,
    Tooltip,
    Typography,
    useTheme,
} from "@wso2/oxygen-ui";
import { AreaChart } from "@wso2/oxygen-ui-charts-react";
import { CheckCircle, ChevronRight, PauseCircle, XCircle } from "@wso2/oxygen-ui-icons-react";
import {
    useGetAgentMetrics,
    useListAgentDeployments,
    useTraceList,
} from "@agent-management-platform/api-client";
import { NoDataFound, scoreColor } from "@agent-management-platform/views";
import {
    absoluteRouteMap,
    TraceListTimeRange,
} from "@agent-management-platform/types";
import { format } from "date-fns";
import { generatePath, Link, useNavigate } from "react-router-dom";

interface EnvObservabilitySectionProps {
    orgId: string;
    projectId: string;
    agentId: string;
    envId: string;
    hideMetrics?: boolean;
    external?: boolean;
}

const formatCpu = (cores: number): string => {
    const milli = Math.round(cores * 1000);
    return milli >= 1000 ? `${(milli / 1000).toFixed(2)} cores` : `${milli}m`;
};

const formatMemory = (bytes: number): string => {
    if (bytes >= 1024 ** 3) return `${(bytes / 1024 ** 3).toFixed(1)} GB`;
    if (bytes >= 1024 ** 2) return `${(bytes / 1024 ** 2).toFixed(0)} MB`;
    return `${Math.round(bytes / 1024)} KB`;
};

const formatDuration = (nanos: number): string => {
    const ms = nanos / 1_000_000;
    if (ms < 1000) return `${Math.round(ms)}ms`;
    return `${(ms / 1000).toFixed(1)}s`;
};

interface MetricCardProps {
    label: string;
    value: string;
    points: Array<{ time: string; value: number }>;
    color?: string;
    isLoading?: boolean;
}

const MetricCard: React.FC<MetricCardProps> = ({ label, value, points, color = "currentColor", isLoading }) => (
    <Card variant="outlined" sx={{ flex: 1, minWidth: 0 }}>
        <CardContent sx={{ py: 1, px: 1.5, "&:last-child": { pb: 1 }, display: "flex", alignItems: "center", justifyContent: "space-between", gap: 1 }}>
            <Box>
                {isLoading
                    ? <Skeleton variant="text" width={48} height={28} />
                    : <Typography variant="h6" lineHeight={1.2}>{value}</Typography>
                }
                <Typography variant="caption" color="text.secondary">{label}</Typography>
            </Box>
            {isLoading
                ? <Skeleton variant="rounded" width={120} height={48} />
                : (
                    <AreaChart
                        data={points}
                        xAxisDataKey="time"
                        height={48}
                        width={120}
                        xAxis={{ show: false }}
                        yAxis={{ show: false }}
                        grid={{ show: false }}
                        tooltip={{ show: false }}
                        legend={{ show: false }}
                        margin={{ top: 4, right: 0, bottom: 0, left: 0 }}
                        areas={[{
                            dataKey: "value",
                            stroke: color,
                            fill: color,
                            fillOpacity: 0.15,
                            dot: false,
                            activeDot: false,
                            connectNulls: true,
                            isAnimationActive: false,
                            type: "monotone",
                        }]}
                    />
                )
            }
        </CardContent>
    </Card>
);

export const EnvObservabilitySection: React.FC<EnvObservabilitySectionProps> = ({
    orgId, projectId, agentId, envId, hideMetrics = false, external = false,
}) => {
    const theme = useTheme();
    const navigate = useNavigate();
    const { data: deployments } = useListAgentDeployments(
        { orgName: orgId, projName: projectId, agentName: agentId },
        { enabled: !external },
    );
    const isSuspended = !external && deployments?.[envId]?.status === "suspended";

    const { data: metrics, isLoading: isMetricsLoading } = useGetAgentMetrics(
        { agentName: agentId, orgName: orgId, projName: projectId },
        { environmentName: envId },
        {
            enabled: !hideMetrics && !isSuspended,
            enableAutoRefresh: true,
            timeRange: TraceListTimeRange.ONE_HOUR,
        },
    );

    const { traceList, isLoading: isTracesLoading } = useTraceList(
        orgId, projectId, agentId, envId, TraceListTimeRange.ONE_HOUR, 5, "desc",
        undefined, undefined, { enableAutoRefresh: true },
    );

    const cpuPts = metrics?.cpuUsage ?? [];
    const latestCpu = cpuPts.length ? cpuPts[cpuPts.length - 1].value : null;

    const memPts = metrics?.memory ?? [];
    const latestMemory = memPts.length ? memPts[memPts.length - 1].value : null;

    const traces = traceList?.traces ?? [];

    const tracesHref = generatePath(
        absoluteRouteMap.children.org.children.projects.children.agents
            .children.environment.children.observability.children.traces.path,
        { orgId, projectId, agentId, envId },
    );

    const metricsHref = generatePath(
        absoluteRouteMap.children.org.children.projects.children.agents
            .children.environment.children.observability.children.metrics.path,
        { orgId, projectId, agentId, envId },
    );

    return (
        <>
            {!hideMetrics && (isSuspended ? (
                <NoDataFound
                    iconElement={PauseCircle}
                    message="Environment Suspended"
                    subtitle="Metrics are unavailable while the environment is suspended."
                    disableBackground
                />
            ) : (
                <>
                    <Divider sx={{ mt: 2, mb: 1.5 }} />
                    <Box display="flex" justifyContent="space-between" alignItems="center" mb={1}>
                        <Typography variant="caption" color="text.secondary" fontWeight={600}
                            sx={{ textTransform: "uppercase", letterSpacing: "0.05em" }}>
                            Metrics
                        </Typography>
                        <Button
                            size="small"
                            variant="text"
                            endIcon={<ChevronRight size={14} />}
                            component={Link}
                            to={metricsHref}
                            sx={{ minWidth: 0, fontSize: "0.75rem" }}
                        >
                            View all
                        </Button>
                    </Box>
                    <Stack direction="row" spacing={1.5}>
                        <MetricCard
                            label="CPU Usage"
                            value={latestCpu !== null ? formatCpu(latestCpu) : "—"}
                            points={cpuPts}
                            color={theme.vars?.palette?.info?.main}
                            isLoading={isMetricsLoading}
                        />
                        <MetricCard
                            label="Memory Usage"
                            value={latestMemory !== null ? formatMemory(latestMemory) : "—"}
                            points={memPts}
                            color={theme.vars?.palette?.info?.main}
                            isLoading={isMetricsLoading}
                        />
                    </Stack>
                </>
            ))}
            <Divider sx={{ mt: 1.5, mb: 1 }} />
            <Box display="flex" justifyContent="space-between" alignItems="center" mb={0.5}>
                <Typography variant="caption" color="text.secondary" fontWeight={600}
                    sx={{ textTransform: "uppercase", letterSpacing: "0.05em" }}>
                    Recent Traces
                </Typography>
                <Button
                    size="small"
                    variant="text"
                    endIcon={<ChevronRight size={14} />}
                    component={Link}
                    to={tracesHref}
                    sx={{ minWidth: 0, fontSize: "0.75rem" }}
                >
                    View all
                </Button>
            </Box>
            {isTracesLoading ? (
                <Stack spacing={0.75}>
                    {[1, 2, 3].map((i) => <Skeleton key={i} variant="rounded" height={36} />)}
                </Stack>
            ) : traces.length === 0 ? (
                <Typography variant="body2" color="text.secondary">
                    No traces in the last hour.
                </Typography>
            ) : (
                <ListingTable.Container>
                    <ListingTable>
                        <ListingTable.Head>
                            <ListingTable.Row>
                                <ListingTable.Cell align="center" width="4%">Status</ListingTable.Cell>
                                <ListingTable.Cell align="left" width="14%">Name</ListingTable.Cell>
                                <ListingTable.Cell align="left" width="24%">Input</ListingTable.Cell>
                                <ListingTable.Cell align="center" width="14%">Start Time</ListingTable.Cell>
                                <ListingTable.Cell align="right" width="9%">Duration</ListingTable.Cell>
                                <ListingTable.Cell align="right" width="11%">Tokens</ListingTable.Cell>
                                <ListingTable.Cell align="right" width="11%">Spans</ListingTable.Cell>
                                <ListingTable.Cell align="right" width="13%">Score</ListingTable.Cell>
                            </ListingTable.Row>
                        </ListingTable.Head>
                        <ListingTable.Body>
                            {traces.map((trace) => {
                                const errorCount = trace.status?.errorCount ?? 0;
                                const isError = errorCount > 0;
                                const tu = trace.tokenUsage;
                                const hasTokens = tu?.totalTokens != null;
                                return (
                                    <ListingTable.Row
                                        key={trace.traceId}
                                        hover
                                        clickable
                                        onClick={() => navigate(`${tracesHref}?selectedTrace=${trace.traceId}`)}
                                    >
                                        <ListingTable.Cell
                                            align="center"
                                            sx={{
                                                color: (t) => isError
                                                    ? t.vars?.palette?.error?.main
                                                    : t.vars?.palette?.success?.main,
                                            }}
                                        >
                                            <Tooltip
                                                title={isError ? `${errorCount} error${errorCount > 1 ? "s" : ""}` : "OK"}
                                                disableHoverListener={!isError}
                                            >
                                                {isError
                                                    ? <XCircle size={16} />
                                                    : <CheckCircle size={16} />}
                                            </Tooltip>
                                        </ListingTable.Cell>
                                        <ListingTable.Cell align="left">
                                            <Typography variant="caption" component="span" noWrap display="block" sx={{ maxWidth: 160 }}>
                                                {trace.rootSpanName}
                                            </Typography>
                                        </ListingTable.Cell>
                                        <ListingTable.Cell align="left" sx={{ maxWidth: 240 }}>
                                            <Tooltip title="Preview only. Open the trace for the full input." disableHoverListener={!trace.input}>
                                                <Typography variant="caption" component="span" noWrap display="block" sx={{ maxWidth: "100%" }}>
                                                    {trace.input ?? "—"}
                                                </Typography>
                                            </Tooltip>
                                        </ListingTable.Cell>
                                        <ListingTable.Cell align="center">
                                            <Typography variant="caption" component="span">
                                                {format(new Date(trace.startTime), "yyyy-MM-dd HH:mm:ss")}
                                            </Typography>
                                        </ListingTable.Cell>
                                        <ListingTable.Cell align="right">
                                            <Typography variant="caption" component="span">
                                                {formatDuration(trace.durationInNanos)}
                                            </Typography>
                                        </ListingTable.Cell>
                                        <ListingTable.Cell align="right">
                                            <Tooltip
                                                disableHoverListener={!hasTokens}
                                                title={hasTokens ? (tu?.partial ? "Approximate total" : `${tu?.inputTokens} in / ${tu?.outputTokens} out`) : ""}
                                            >
                                                <Typography variant="caption" component="span">
                                                    {hasTokens ? <>{tu!.totalTokens}{tu?.partial ? "+" : null}</> : "—"}
                                                </Typography>
                                            </Tooltip>
                                        </ListingTable.Cell>
                                        <ListingTable.Cell align="right">
                                            <Typography variant="caption" component="span">
                                                {trace.spanCount}
                                            </Typography>
                                        </ListingTable.Cell>
                                        <ListingTable.Cell align="right">
                                            {trace.score?.score != null ? (
                                                <Tooltip title={`${trace.score.totalCount} evaluations, ${trace.score.skippedCount} skipped`}>
                                                    <Typography
                                                        variant="caption"
                                                        component="span"
                                                        sx={{
                                                            color: scoreColor(trace.score.score),
                                                            fontWeight: 600,
                                                        }}
                                                    >
                                                        {(trace.score.score * 100).toFixed(1)}%
                                                    </Typography>
                                                </Tooltip>
                                            ) : (
                                                <Typography variant="caption" component="span">—</Typography>
                                            )}
                                        </ListingTable.Cell>
                                    </ListingTable.Row>
                                );
                            })}
                        </ListingTable.Body>
                    </ListingTable>
                </ListingTable.Container>
            )}
        </>
    );
};
